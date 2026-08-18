# tools/history/build_evolution_lab.ps1
# Build script for Sibambo BOM Engine Evolution Lab

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Resolve-Path (Join-Path $scriptDir "..\..")
$rubyScript = Join-Path $scriptDir "build_evolution_lab.rb"

Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "  Building Sibambo BOM Engine Evolution Lab..." -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan

& ruby $rubyScript

if ($LASTEXITCODE -ne 0) {
    Write-Error "Evolution Lab build failed with exit code $LASTEXITCODE"
    exit $LASTEXITCODE
}

Write-Host "`nBuild succeeded! Artifacts available in dist/history/" -ForegroundColor Green
