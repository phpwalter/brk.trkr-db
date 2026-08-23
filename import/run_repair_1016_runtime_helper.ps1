param(
    [string]$SchemaRoot = "..\master.schema",
    [switch]$Apply
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PythonScript = Join-Path $ScriptDir "repair_1016_runtime_helper.py"

$ArgsList = @(
    "-X","utf8",
    $PythonScript,
    "--schema-root",$SchemaRoot
)

if ($Apply) {
    $ArgsList += "--apply"
}

& python @ArgsList
exit $LASTEXITCODE
