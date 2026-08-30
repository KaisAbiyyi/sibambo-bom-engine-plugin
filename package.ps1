$ErrorActionPreference = 'Stop'

$Version = '1.2.0'
$PluginDir = $PSScriptRoot
$RootDir = Split-Path -Parent $PluginDir
$Head = (& git -C $PluginDir rev-parse HEAD).Trim()
if ($Head -notmatch '^[0-9a-f]{40}$') { throw "Cannot resolve current producer HEAD: $Head" }
$ShortHead = $Head.Substring(0, 12)
$OutputPath = Join-Path $RootDir "Sibambo-BOMC-Engine-v$Version-build-$ShortHead.rbz"
$StagingDir = Join-Path ([System.IO.Path]::GetTempPath()) "bom-engine-rbz-$([guid]::NewGuid())"
$ZipPath = [System.IO.Path]::ChangeExtension($OutputPath, '.zip')

try {
    New-Item -ItemType Directory -Path $StagingDir | Out-Null
    Copy-Item -LiteralPath (Join-Path $PluginDir 'bom_engine_loader.rb') -Destination $StagingDir
    Copy-Item -LiteralPath (Join-Path $PluginDir 'bom_engine') -Destination $StagingDir -Recurse
    [IO.File]::WriteAllText((Join-Path $StagingDir 'bom_engine\BUILD_SHA.txt'), "$Head`r`n", [Text.UTF8Encoding]::new($false))
    $TestsPath = Join-Path $StagingDir 'bom_engine\tests'
    if (Test-Path -LiteralPath $TestsPath) {
        Remove-Item -LiteralPath $TestsPath -Recurse -Force
    }
    $GraphifyPath = Join-Path $StagingDir 'bom_engine\graphify-out'
    if (Test-Path -LiteralPath $GraphifyPath) {
        Remove-Item -LiteralPath $GraphifyPath -Recurse -Force
    }
    if (Test-Path -LiteralPath $ZipPath) {
        Remove-Item -LiteralPath $ZipPath -Force
    }
    if (Test-Path -LiteralPath $OutputPath) {
        Remove-Item -LiteralPath $OutputPath -Force
    }
    Compress-Archive -Path (Join-Path $StagingDir '*') -DestinationPath $ZipPath -CompressionLevel Optimal
    Move-Item -LiteralPath $ZipPath -Destination $OutputPath
    Write-Output "Built: $OutputPath"
} finally {
    if (Test-Path -LiteralPath $StagingDir) {
        Remove-Item -LiteralPath $StagingDir -Recurse -Force
    }
}
