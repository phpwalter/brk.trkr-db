param(
    [string]$SchemaRoot = "..\master.schema",
    [switch]$Apply
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PythonScript = Join-Path $ScriptDir "canonicalize_rebrickable_phase6.py"

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
