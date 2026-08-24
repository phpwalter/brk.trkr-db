Set-StrictMode -Version Latest

function Import-BrickTrackrDatabaseConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath
    )

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "BrickTrackr config file not found: $ConfigPath"
    }

    $section = $null
    $values = @{}

    foreach ($rawLine in Get-Content -LiteralPath $ConfigPath -ErrorAction Stop) {
        $line = $rawLine.Trim()

        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        if ($line.StartsWith(";") -or $line.StartsWith("#")) {
            continue
        }

        if ($line -match '^\[(.+)\]$') {
            $section = $Matches[1].Trim().ToLowerInvariant()
            continue
        }

        if ($section -ne "database") {
            continue
        }

        if ($line -match '^([^=]+)=(.*)$') {
            $key = $Matches[1].Trim().ToLowerInvariant()
            $value = $Matches[2].Trim()
            $values[$key] = $value
        }
    }

    foreach ($required in @("host", "port", "admin_user", "database")) {
        if (-not $values.ContainsKey($required) -or
            [string]::IsNullOrWhiteSpace($values[$required])) {
            throw "Missing required [database] setting '$required' in $ConfigPath"
        }
    }

    $portValue = 0
    if (-not [int]::TryParse($values["port"], [ref]$portValue)) {
        throw "Invalid [database] port '$($values["port"])' in $ConfigPath"
    }

    if ($portValue -lt 1 -or $portValue -gt 65535) {
        throw "Database port out of range: $portValue"
    }

    # Export process-scoped variables so child PowerShell, Python and psql
    # processes inherit the same connection settings.
    $env:BRICKTRACKR_DB_HOST = $values["host"]
    $env:BRICKTRACKR_DB_PORT = [string]$portValue
    $env:BRICKTRACKR_DB_ADMIN_USER = $values["admin_user"]
    $env:BRICKTRACKR_DATABASE = $values["database"]

    return [pscustomobject]@{
        HostName  = $env:BRICKTRACKR_DB_HOST
        Port      = [int]$env:BRICKTRACKR_DB_PORT
        AdminUser = $env:BRICKTRACKR_DB_ADMIN_USER
        Database  = $env:BRICKTRACKR_DATABASE
        ConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
    }
}

function Write-BrickTrackrDatabaseConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Config
    )

    Write-Host "[CONFIG] Host:       $($Config.HostName)"
    Write-Host "[CONFIG] Port:       $($Config.Port)"
    Write-Host "[CONFIG] Admin user: $($Config.AdminUser)"
    Write-Host "[CONFIG] Database:   $($Config.Database)"
    Write-Host "[CONFIG] File:       $($Config.ConfigPath)"
}
