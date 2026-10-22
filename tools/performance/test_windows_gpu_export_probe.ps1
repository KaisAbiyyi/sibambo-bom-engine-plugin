# Offline P0 diagnostic preflight test. Writes only to D: and does not control SketchUp.
param([string]$InstallReceipt, [string]$PackageRbz)
$ErrorActionPreference = 'Stop'
$probe = Join-Path $PSScriptRoot 'windows_gpu_export_probe.ps1'
$tokens = $null; $errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($probe, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) { throw "PowerShell parser rejected $($errors.Count) errors." }

$root = 'D:\projects\sibambo\scratch\perf-gpu-00\offline-tests'
$id = 'test_' + [guid]::NewGuid().ToString('N')
if ([bool]$InstallReceipt -ne [bool]$PackageRbz) {
    throw 'Supply both -InstallReceipt and -PackageRbz, or neither for portable offline validation.'
}
& $probe -Mode Snapshot -OutputRoot $root -RunId $id -InstallReceipt $InstallReceipt -PackageRbz $PackageRbz | Out-Null
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw 'Snapshot failed.' }
$hostResult = Get-Content -LiteralPath (Join-Path $root "$id\host.json") -Raw | ConvertFrom-Json
if ($InstallReceipt) {
    if ($hostResult.installed_source_markers.Count -ne 2 -or
        @($hostResult.installed_source_markers | Where-Object { -not $_.matches_install_receipt }).Count -ne 0) {
        throw 'Installed source marker pins do not agree with receipt.'
    }
}
if ($hostResult.loaded_exporter_source_verified) { throw 'Disk source hashes must not prove active Ruby loading.' }

$refused = $false
try {
    & $probe -Mode Capture -OutputRoot $root -RunId "$($id)_without_claim" -Samples 1 | Out-Null
} catch {
    $refused = ($_.Exception.Message -like '*HostClaimConfirmed*')
}
if (-not $refused) { throw 'Real capture without exclusive host assertion must be rejected.' }
if (Test-Path (Join-Path $root "$($id)_without_claim")) { throw 'Rejected capture unexpectedly wrote an output.' }

& $probe -Mode Finalize -OutputRoot $root -RunId $id | Out-Null
$final = Get-Content -LiteralPath (Join-Path $root "$id\final.json") -Raw | ConvertFrom-Json
if ($final.trace_status -ne 'NOT_RUN' -or $final.causal_attribution -ne 'NOT_ESTABLISHED' -or
    $final.adapter_luid_mapping_verified -or $final.provenance_loaded_source_verified) {
    throw 'Snapshot-only finalization must remain explicitly unverified.'
}
Write-Output "PASS: syntax, provenance pins, exclusive claim refusal, no-native-proof receipt ($id)"
