param(
    [string]$SchemaRoot = "..\master.schema",
    [switch]$Apply
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$ArgsList = @(
    "-X","utf8",
    (Join-Path $ScriptDir "repair_phase6_bootstrap_order.py"),
    "--schema-root",$SchemaRoot
)

if ($Apply) {
    $ArgsList += "--apply"
}

& python @ArgsList
exit $LASTEXITCODE
