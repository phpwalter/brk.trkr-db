param(
    [string]$SchemaRoot = "..\master.schema"
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

& python -X utf8 `
    (Join-Path $ScriptDir "diagnose_1016_runtime_helpers.py") `
    --schema-root $SchemaRoot

exit $LASTEXITCODE
