# tools/history/install_evolution_lab.ps1
# Installer for Sibambo BOM Engine Evolution Lab

[CmdletBinding()]
param(
    [string]$SketchUpVersion = '',
    [switch]$Force = $false
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptPath = $MyInvocation.MyCommand.Path
$rootDir = Resolve-Path (Join-Path $scriptDir '..\..')
$stagingDir = Join-Path $rootDir 'dist\history\staging'
$masterRbz = Join-Path $rootDir 'dist\history\sibambo_bom_engine_evolution_lab_v1.0.0.rbz'

Write-Host '======================================================================' -ForegroundColor Cyan
Write-Host '  SIBAMBO BOM ENGINE — EVOLUTION LAB INSTALLER' -ForegroundColor Cyan
Write-Host '======================================================================' -ForegroundColor Cyan

# 1. Detect installed SketchUp versions
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

if ($detectedVersions.Count -eq 0) {
    Write-Error ('No SketchUp Plugins directory found under ' + $sketchUpBase)
    exit 1
}

Write-Host 'Detected SketchUp Plugin Directories:' -ForegroundColor Yellow
$detectedVersions | ForEach-Object {
    Write-Host ('  - ' + $_.Name + ': ' + $_.PluginsPath)
}

# Select target version
$target = $null
if ($SketchUpVersion -ne '') {
    $target = $detectedVersions | Where-Object { $_.Name -like ('*' + $SketchUpVersion + '*') } | Select-Object -First 1
    if ($null -eq $target) {
        Write-Error ('Specified SketchUp version ' + $SketchUpVersion + ' not found among detected versions.')
        exit 1
    }
} else {
    # Default to newest version (highest sort order)
    $target = $detectedVersions | Sort-Object -Property Name -Descending | Select-Object -First 1
}

Write-Host ''
Write-Host ('Target SketchUp: ' + $target.Name) -ForegroundColor Green
Write-Host ('Target Plugins:  ' + $target.PluginsPath) -ForegroundColor Green

# 2. Check if SketchUp is currently running
$sketchUpProcesses = Get-Process -Name 'SketchUp' -ErrorAction SilentlyContinue

if ($sketchUpProcesses.Count -gt 0 -and -not $Force) {
    Write-Host ''
    Write-Host '======================================================================' -ForegroundColor Red
    Write-Host '  INSTALL_PENDING: SketchUp is currently running!' -ForegroundColor Red
    Write-Host '======================================================================' -ForegroundColor Red
    Write-Host 'Evolution Lab was NOT installed to avoid file lock / reload issues.'
    Write-Host 'Please close SketchUp and run this command:' -ForegroundColor Yellow
    Write-Host ('  powershell -ExecutionPolicy Bypass -File ' + $scriptPath) -ForegroundColor White
    exit 2
}

# 3. Check staging build
if (-not (Test-Path $stagingDir)) {
    Write-Host 'Staging build not found. Running build_evolution_lab.ps1 first...' -ForegroundColor Yellow
    $buildScript = Join-Path $scriptDir 'build_evolution_lab.ps1'
    & $buildScript
}

$loaderSrc = Join-Path $stagingDir 'sibambo_evolution_lab_loader.rb'
$labDirSrc = Join-Path $stagingDir 'evolution_lab'

if (-not (Test-Path $loaderSrc) -or -not (Test-Path $labDirSrc)) {
    Write-Error ('Staging files missing: ' + $loaderSrc + ' or ' + $labDirSrc)
    exit 1
}

$destLoader = Join-Path $target.PluginsPath 'sibambo_evolution_lab_loader.rb'
$destLabDir = Join-Path $target.PluginsPath 'evolution_lab'

# 4. Backup existing Evolution Lab installation
if (Test-Path $destLabDir) {
    $nowStr = Get-Date -Format 'yyyyMMdd_HHmmss'
    $backupDir = Join-Path $target.PluginsPath ('evolution_lab_backup_' + $nowStr)
    Write-Host ('Backing up existing Evolution Lab to: ' + $backupDir) -ForegroundColor Gray
    Move-Item -Path $destLabDir -Destination $backupDir -Force
    if (Test-Path $destLoader) {
        Remove-Item -Path $destLoader -Force
    }
}

# 5. Atomic Install
Write-Host 'Installing Evolution Lab...' -ForegroundColor Cyan
Copy-Item -Path $loaderSrc -Destination $destLoader -Force
Copy-Item -Path $labDirSrc -Destination $destLabDir -Recurse -Force

# 6. Verification
$verified = $true
if (-not (Test-Path $destLoader)) { $verified = $false }
$menuFile = Join-Path $destLabDir 'master_menu.rb'
if (-not (Test-Path $menuFile)) { $verified = $false }

if ($verified) {
    Write-Host ''
    Write-Host '[SUCCESS] Sibambo BOM Engine Evolution Lab successfully installed!' -ForegroundColor Green
    Write-Host ('Installed Loader: ' + $destLoader)
    Write-Host ('Installed Core:   ' + $destLabDir)
    Write-Host 'Production BOM Engine remains intact and untouched.'
} else {
    Write-Error 'Installation verification failed.'
    exit 1
}
