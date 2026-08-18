# tools/history/uninstall_evolution_lab.ps1
# Uninstaller for Sibambo BOM Engine Evolution Lab

[CmdletBinding()]
param(
    [string]$SketchUpVersion = ''
)

$ErrorActionPreference = 'Stop'

Write-Host '======================================================================' -ForegroundColor Cyan
Write-Host '  SIBAMBO BOM ENGINE — EVOLUTION LAB UNINSTALLER' -ForegroundColor Cyan
Write-Host '======================================================================' -ForegroundColor Cyan

$appData = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
$sketchUpBase = Join-Path $appData 'SketchUp'

if (-not (Test-Path $sketchUpBase)) {
    Write-Error ('No SketchUp installation directory found under: ' + $sketchUpBase)
    exit 1
}

$detectedVersions = @()
Get-ChildItem -Path $sketchUpBase -Directory | ForEach-Object {
    $verName = $_.Name
    $pluginsPath = Join-Path $_.FullName 'SketchUp\Plugins'
    if (Test-Path $pluginsPath) {
        $detectedVersions += [PSCustomObject]@{
            Name        = $verName
            PluginsPath = $pluginsPath
        }
    }
}

$targets = @()
if ($SketchUpVersion -ne '') {
    $targets = $detectedVersions | Where-Object { $_.Name -like ('*' + $SketchUpVersion + '*') }
} else {
    $targets = $detectedVersions
}

$targets | ForEach-Object {
    $pPath = $_.PluginsPath
    Write-Host ''
    Write-Host ('Checking: ' + $_.Name) -ForegroundColor Yellow
    
    $loader = Join-Path $pPath 'sibambo_evolution_lab_loader.rb'
    $labDir = Join-Path $pPath 'evolution_lab'

    if (Test-Path $loader) {
        Remove-Item -Path $loader -Force
        Write-Host ('  Removed: ' + $loader) -ForegroundColor Green
    }
    if (Test-Path $labDir) {
        Remove-Item -Path $labDir -Recurse -Force
        Write-Host ('  Removed: ' + $labDir) -ForegroundColor Green
    }
}

Write-Host ''
Write-Host '[SUCCESS] Evolution Lab uninstalled cleanly. Production BOM Engine remains untouched.' -ForegroundColor Green
