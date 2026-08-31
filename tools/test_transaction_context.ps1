<#
.SYNOPSIS
    Runs BrickTrackr transaction-context behavioral and role-matrix tests.

.DESCRIPTION
    File:    tools\test_transaction_context.ps1
    Version: 1.1.0

    Fixture resolution changed in v1.1.0:
      The previous runner attempted to SELECT identity.users through
      brktrkr_owner_login. With FORCE ROW LEVEL SECURITY, the owner capability
      is intentionally not a universal visibility bypass, so that lookup can
      legitimately return zero rows.

      v1.1.0 resolves a fixture through the approved administrative procedure
      surface using brktrkr_admin_login and admin.list_users(...), which is the
      correct privileged read boundary for identity.users.

    The runner then:
      * executes tests\transaction_context.sql as brktrkr_api_login;
      * proves positive actor/capability mappings;
      * proves negative cross-capability mappings;
      * verifies the supplied/resolved fixture exists through the canonical
        USER setter path.

.NOTES
    Local development defaults use password "root".
#>

[CmdletBinding()]
param(
    [string]$HostName = "localhost",
    [int]$Port = 5432,
    [string]$Database = "bricktrackr",

    [string]$ApiUser = "brktrkr_api_login",
    [string]$ApiPassword = "root",

    [string]$AdminUser = "brktrkr_admin_login",
    [string]$AdminPassword = "root",

    [string]$ImportUser = "brktrkr_import_login",
    [string]$ImportPassword = "root",

    [string]$MigratorUser = "brktrkr_migrator_login",
    [string]$MigratorPassword = "root",

    [string]$OwnerUser = "brktrkr_owner_login",
    [string]$OwnerPassword = "root",

    [string]$FixtureUser = "",
    [string]$SqlFile = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$FileVersion = "1.1.0"

function Write-Section {
    param([Parameter(Mandatory = $true)][string]$Title)

    Write-Host ""
    Write-Host "==============================================================================="
    Write-Host " $Title"
    Write-Host "==============================================================================="
}

function Write-Pass {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[PASS] $Message"
}

function Write-Run {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[RUN ] $Message"
}

function Find-Psql {
    $Candidates = @(
        "L:\etc\postgresql\bin\psql.exe"
    )

    foreach ($Candidate in $Candidates) {
        if (Test-Path -LiteralPath $Candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $Candidate).Path
        }
    }

    $Cmd = Get-Command psql.exe -ErrorAction SilentlyContinue
    if (-not $Cmd) {
        $Cmd = Get-Command psql -ErrorAction SilentlyContinue
    }

    if (-not $Cmd) {
        throw "psql was not found."
    }

    return $Cmd.Source
}

function Invoke-Psql {
    param(
        [Parameter(Mandatory = $true)][string]$Username,
        [Parameter(Mandatory = $true)][string]$Password,
        [string]$Sql = "",
        [string]$File = "",
        [hashtable]$Variables = @{},
        [switch]$TuplesOnly,
        [switch]$AllowFailure
    )

    $PreviousPassword = $env:PGPASSWORD
    $HadPassword = Test-Path Env:PGPASSWORD

    try {
        $env:PGPASSWORD = $Password

        $Args = @(
            "-X",
            "-v", "ON_ERROR_STOP=1",
            "-h", $HostName,
            "-p", $Port.ToString(),
            "-U", $Username,
            "-d", $Database
        )

        if ($TuplesOnly) {
            $Args += @("-t", "-A")
        }

        foreach ($Key in ($Variables.Keys | Sort-Object)) {
            $Args += @("-v", "$Key=$($Variables[$Key])")
        }

        if (-not [string]::IsNullOrWhiteSpace($File)) {
            $Args += @("-f", $File)
        }
        elseif (-not [string]::IsNullOrWhiteSpace($Sql)) {
            $Args += @("-c", $Sql)
        }
        else {
            throw "Invoke-Psql requires -Sql or -File."
        }

        $PreviousPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"

        try {
            $Output = & $script:PsqlPath @Args 2>&1
            $ExitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $PreviousPreference
        }

        if (-not $AllowFailure -and $ExitCode -ne 0) {
            throw (
                "psql failed for $Username with exit code $ExitCode.`n" +
                ($Output -join [Environment]::NewLine)
            )
        }

        return [PSCustomObject]@{
            ExitCode = $ExitCode
            Output = @($Output)
        }
    }
    finally {
        if ($HadPassword) {
            $env:PGPASSWORD = $PreviousPassword
        }
        else {
            Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
        }
    }
}

function Resolve-FixtureUser {
    if (-not [string]::IsNullOrWhiteSpace($FixtureUser)) {
        try {
            $null = [Guid]::Parse($FixtureUser)
        }
        catch {
            throw "-FixtureUser is not a valid UUID: $FixtureUser"
        }

        Write-Pass "Using caller-supplied fixture identity: $FixtureUser"
        return $FixtureUser
    }

    Write-Run "Resolve an existing BrickTrackr identity through admin.list_users()"

    $Sql = @"
CALL admin.list_users(
    p_management_type  => NULL::identity.account_management_type,
    p_status           => NULL::identity.account_status,
    p_search           => NULL::text,
    p_include_archived => TRUE,
    p_limit            => 1,
    p_offset           => 0,
    p_result           => NULL::jsonb
);
"@

    $Result = Invoke-Psql `
        -Username $AdminUser `
        -Password $AdminPassword `
        -Sql $Sql `
        -TuplesOnly

    $JsonLine = @(
        $Result.Output |
        ForEach-Object { $_.ToString().Trim() } |
        Where-Object { $_ -match '^\{.*\}$' }
    ) | Select-Object -First 1

    if ([string]::IsNullOrWhiteSpace($JsonLine)) {
        throw "admin.list_users() returned no parseable JSON result."
    }

    try {
        $Payload = $JsonLine | ConvertFrom-Json
    }
    catch {
        throw "admin.list_users() returned invalid JSON: $JsonLine"
    }

    if ($null -eq $Payload.users -or $Payload.users.Count -lt 1) {
        throw "identity.users contains no fixture row. Create at least one BrickTrackr user before running this suite."
    }

    $Resolved = [string]$Payload.users[0].user_id

    try {
        $null = [Guid]::Parse($Resolved)
    }
    catch {
        throw "admin.list_users() returned an invalid user UUID: $Resolved"
    }

    Write-Pass "Resolved fixture identity through approved admin procedure: $Resolved"
    return $Resolved
}

function Invoke-ExpectedSuccess {
    param(
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][string]$Username,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$Sql
    )

    Write-Run $Description

    $Result = Invoke-Psql `
        -Username $Username `
        -Password $Password `
        -Sql $Sql `
        -AllowFailure

    if ($Result.ExitCode -ne 0) {
        throw (
            "$Description unexpectedly failed.`n" +
            ($Result.Output -join [Environment]::NewLine)
        )
    }

    Write-Pass $Description
}

function Invoke-ExpectedFailure {
    param(
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][string]$Username,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$Sql
    )

    Write-Run $Description

    $Result = Invoke-Psql `
        -Username $Username `
        -Password $Password `
        -Sql $Sql `
        -AllowFailure

    if ($Result.ExitCode -eq 0) {
        throw "$Description unexpectedly succeeded."
    }

    Write-Pass $Description
}

try {
    $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    $RepoRoot = Split-Path -Parent $ScriptRoot

    if ([string]::IsNullOrWhiteSpace($SqlFile)) {
        $SqlFile = Join-Path $RepoRoot "tests\transaction_context.sql"
    }
    elseif (-not [System.IO.Path]::IsPathRooted($SqlFile)) {
        $SqlFile = Join-Path $RepoRoot $SqlFile
    }

    if (-not (Test-Path -LiteralPath $SqlFile -PathType Leaf)) {
        throw "Transaction-context SQL test file does not exist: $SqlFile"
    }

    $script:PsqlPath = Find-Psql

    Write-Section "BrickTrackr Transaction Context Verification"
    Write-Host "Version:  $FileVersion"
    Write-Host "Database: $HostName`:$Port/$Database"
    Write-Host "psql:     $script:PsqlPath"
    Write-Host "SQL:      $SqlFile"

    $ResolvedFixture = Resolve-FixtureUser

    Write-Section "1. Direct Behavioral Suite"

    Write-Run "Execute transaction-context behavioral SQL as $ApiUser"

    $Direct = Invoke-Psql `
        -Username $ApiUser `
        -Password $ApiPassword `
        -File $SqlFile `
        -Variables @{ user_id = $ResolvedFixture } `
        -AllowFailure

    $Direct.Output | ForEach-Object { Write-Host $_ }

    if ($Direct.ExitCode -ne 0) {
        throw "Transaction-context behavioral SQL failed with exit code $($Direct.ExitCode)."
    }

    Write-Pass "Transaction-context behavioral SQL"

    $RequestId = [Guid]::NewGuid().ToString()

    Write-Section "2. Positive Actor/Capability Matrix"

    Invoke-ExpectedSuccess `
        -Description "API capability may establish USER context" `
        -Username $ApiUser `
        -Password $ApiPassword `
        -Sql "BEGIN; SELECT app.set_request_context('$ResolvedFixture'::uuid, '$RequestId'::uuid, 'api-positive', 'USER'); ROLLBACK;"

    Invoke-ExpectedSuccess `
        -Description "Admin capability may establish ADMIN context" `
        -Username $AdminUser `
        -Password $AdminPassword `
        -Sql "BEGIN; SELECT app.set_request_context(NULL::uuid, '$([Guid]::NewGuid())'::uuid, 'admin-positive', 'ADMIN'); ROLLBACK;"

    Invoke-ExpectedSuccess `
        -Description "Import capability may establish IMPORTER context" `
        -Username $ImportUser `
        -Password $ImportPassword `
        -Sql "BEGIN; SELECT app.set_request_context(NULL::uuid, '$([Guid]::NewGuid())'::uuid, 'import-positive', 'IMPORTER'); ROLLBACK;"

    Invoke-ExpectedSuccess `
        -Description "Migrator capability may establish SYSTEM context" `
        -Username $MigratorUser `
        -Password $MigratorPassword `
        -Sql "BEGIN; SELECT app.set_request_context(NULL::uuid, '$([Guid]::NewGuid())'::uuid, 'migrator-positive', 'SYSTEM'); ROLLBACK;"

    Invoke-ExpectedSuccess `
        -Description "Owner capability may establish SYSTEM context" `
        -Username $OwnerUser `
        -Password $OwnerPassword `
        -Sql "BEGIN; SELECT app.set_request_context(NULL::uuid, '$([Guid]::NewGuid())'::uuid, 'owner-positive', 'SYSTEM'); ROLLBACK;"

    Write-Section "3. Negative Actor/Capability Matrix"

    Invoke-ExpectedFailure `
        -Description "API capability must not establish ADMIN context" `
        -Username $ApiUser `
        -Password $ApiPassword `
        -Sql "SELECT app.set_request_context(NULL::uuid, '$([Guid]::NewGuid())'::uuid, 'deny', 'ADMIN');"

    Invoke-ExpectedFailure `
        -Description "API capability must not establish IMPORTER context" `
        -Username $ApiUser `
        -Password $ApiPassword `
        -Sql "SELECT app.set_request_context(NULL::uuid, '$([Guid]::NewGuid())'::uuid, 'deny', 'IMPORTER');"

    Invoke-ExpectedFailure `
        -Description "API capability must not establish SYSTEM context" `
        -Username $ApiUser `
        -Password $ApiPassword `
        -Sql "SELECT app.set_request_context(NULL::uuid, '$([Guid]::NewGuid())'::uuid, 'deny', 'SYSTEM');"

    Invoke-ExpectedFailure `
        -Description "Admin capability must not establish USER context" `
        -Username $AdminUser `
        -Password $AdminPassword `
        -Sql "SELECT app.set_request_context('$ResolvedFixture'::uuid, '$([Guid]::NewGuid())'::uuid, 'deny', 'USER');"

    Invoke-ExpectedFailure `
        -Description "Import capability must not establish USER context" `
        -Username $ImportUser `
        -Password $ImportPassword `
        -Sql "SELECT app.set_request_context('$ResolvedFixture'::uuid, '$([Guid]::NewGuid())'::uuid, 'deny', 'USER');"

    Invoke-ExpectedFailure `
        -Description "Migrator capability must not establish USER context" `
        -Username $MigratorUser `
        -Password $MigratorPassword `
        -Sql "SELECT app.set_request_context('$ResolvedFixture'::uuid, '$([Guid]::NewGuid())'::uuid, 'deny', 'USER');"

    Invoke-ExpectedFailure `
        -Description "Migrator owner-membership must not grant ADMIN context" `
        -Username $MigratorUser `
        -Password $MigratorPassword `
        -Sql "SELECT app.set_request_context(NULL::uuid, '$([Guid]::NewGuid())'::uuid, 'deny', 'ADMIN');"

    Invoke-ExpectedFailure `
        -Description "Migrator owner-membership must not grant IMPORTER context" `
        -Username $MigratorUser `
        -Password $MigratorPassword `
        -Sql "SELECT app.set_request_context(NULL::uuid, '$([Guid]::NewGuid())'::uuid, 'deny', 'IMPORTER');"

    Write-Section "Transaction Context Verification Complete"
    Write-Pass "Behavioral transaction-context contract passed."
    Write-Pass "Actor/capability separation passed."
    Write-Pass "Fixture identity was resolved through the approved admin surface."
    Write-Host "[INFO] Runner version: $FileVersion"

    exit 0
}
catch {
    Write-Host ""
    Write-Host "==============================================================================="
    Write-Host "[FAIL] $($_.Exception.Message)"
    Write-Host "==============================================================================="
    exit 1
}
