param(
    [string]$SourceRunId = "01a0283d-4c30-744e-b3f7-4e96561db0af"
)

$DatabaseHost = "localhost"
$DatabasePort = 5432
$DatabaseName = "bricktrackr"
$DatabaseUser = "bricktrackr_import"

$SecurePassword = Read-Host "Enter PostgreSQL password for '$DatabaseUser'" -AsSecureString
$Bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)

try {
    $PlainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($Bstr)
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Bstr)
}

$env:PGPASSWORD = $PlainPassword
$PlainPassword = $null
$SecurePassword = $null

try {
    psql `
        -X `
        -h $DatabaseHost `
        -p $DatabasePort `
        -U $DatabaseUser `
        -d $DatabaseName `
        -v "run_id=$SourceRunId" `
        -c "SELECT step_order, substep_order, step_name, substep_name, status, rows_processed, rows_expected, percent_complete, batch_count, last_source_row_number, updated_at FROM import.phase3b_progress(:'run_id'::uuid);"
}
finally {
    $env:PGPASSWORD = $null
}
