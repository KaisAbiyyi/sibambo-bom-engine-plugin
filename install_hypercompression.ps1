param(
    [Parameter(Mandatory = $true)]
    [string]$RbzPath,
    [Parameter(Mandatory = $true)]
    [string]$CommitSha,
    [string]$PluginsPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($CommitSha -notmatch '^[0-9a-fA-F]{40}$') {
    throw "CommitSha must be a full 40-character Git SHA. Received '$CommitSha'."
}
$CommitSha = $CommitSha.ToLowerInvariant()
$ExpectedPlugins = [System.IO.Path]::GetFullPath((Join-Path $env:APPDATA 'SketchUp\SketchUp 2026\SketchUp\Plugins'))
if ([string]::IsNullOrWhiteSpace($PluginsPath)) {
    $PluginsPath = $ExpectedPlugins
}
$PluginsPath = [System.IO.Path]::GetFullPath($PluginsPath)
if (-not $PluginsPath.Equals($ExpectedPlugins, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing unexpected SketchUp Plugins destination '$PluginsPath'. Expected '$ExpectedPlugins'."
}
if (-not (Test-Path -LiteralPath $PluginsPath -PathType Container)) {
    throw "SketchUp 2026 Plugins directory does not exist: $PluginsPath"
}
$RbzPath = [System.IO.Path]::GetFullPath($RbzPath)
if (-not (Test-Path -LiteralPath $RbzPath -PathType Leaf)) {
    throw "RBZ not found: $RbzPath"
}

$TemporaryRoot = [System.IO.Path]::GetFullPath((Join-Path ([System.IO.Path]::GetTempPath()) "bomc-install-$([guid]::NewGuid())"))
$StagingPath = Join-Path $TemporaryRoot 'staging'
$BackupRoot = Join-Path $PluginsPath '.bom_engine_backups'
$BackupPath = Join-Path $BackupRoot ("cooperative-{0}-{1}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $CommitSha.Substring(0, 12))
$TargetLoader = Join-Path $PluginsPath 'bom_engine_loader.rb'
$TargetRuntime = Join-Path $PluginsPath 'bom_engine'
$InstallCompleted = $false

function Assert-ChildPath {
    param([string]$Path, [string]$Parent)
    $ResolvedPath = [System.IO.Path]::GetFullPath($Path)
    $ResolvedParent = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
    if (-not $ResolvedPath.StartsWith($ResolvedParent, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing operation outside owned parent: $ResolvedPath"
    }
}

try {
    New-Item -ItemType Directory -Path $StagingPath -Force | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $Archive = [System.IO.Compression.ZipFile]::OpenRead($RbzPath)
    try {
        $EntryNames = @($Archive.Entries | ForEach-Object { $_.FullName })
        foreach ($EntryName in $EntryNames) {
            if ($EntryName.StartsWith('/') -or $EntryName.StartsWith('\') -or $EntryName -match '(^|/|\\)\.\.(/|\\|$)') {
                throw "Unsafe RBZ entry: $EntryName"
            }
        }
    } finally {
        $Archive.Dispose()
    }
    foreach ($Required in @(
        'bom_engine_loader.rb',
        'bom_engine/bomc_extension.rb',
        'bom_engine/bomc_processing.rb',
        'bom_engine/bomc_size_gate.rb',
        'bom_engine/bomc_export_job.rb',
        'bom_engine/bomc_texture_optimizer.rb',
        'bom_engine/ui/conversion_dialog.html'
    )) {
        if ($EntryNames -notcontains $Required) {
            throw "RBZ is missing required entry '$Required'."
        }
    }

    [System.IO.Compression.ZipFile]::ExtractToDirectory($RbzPath, $StagingPath)
    $StagedLoader = Join-Path $StagingPath 'bom_engine_loader.rb'
    $StagedRuntime = Join-Path $StagingPath 'bom_engine'
    if (-not (Select-String -LiteralPath $StagedLoader -Pattern "PLUGIN_VERSION = '3.3.0-rc.1'" -Quiet)) {
        throw 'Staged loader does not declare the cooperative RC version.'
    }

    New-Item -ItemType Directory -Path $BackupPath -Force | Out-Null
    Assert-ChildPath -Path $TargetLoader -Parent $PluginsPath
    Assert-ChildPath -Path $TargetRuntime -Parent $PluginsPath
    if (Test-Path -LiteralPath $TargetLoader) {
        Move-Item -LiteralPath $TargetLoader -Destination (Join-Path $BackupPath 'bom_engine_loader.rb')
    }
    if (Test-Path -LiteralPath $TargetRuntime) {
        Move-Item -LiteralPath $TargetRuntime -Destination (Join-Path $BackupPath 'bom_engine')
    }

    Copy-Item -LiteralPath $StagedLoader -Destination $TargetLoader
    Copy-Item -LiteralPath $StagedRuntime -Destination $TargetRuntime -Recurse
    [System.IO.File]::WriteAllText((Join-Path $TargetRuntime 'BUILD_SHA.txt'), "$CommitSha`n", [System.Text.UTF8Encoding]::new($false))

    $StagedFiles = Get-ChildItem -LiteralPath $StagedRuntime -File -Recurse
    foreach ($StagedFile in $StagedFiles) {
        $Relative = $StagedFile.FullName.Substring($StagedRuntime.Length).TrimStart('\')
        $InstalledFile = Join-Path $TargetRuntime $Relative
        if (-not (Test-Path -LiteralPath $InstalledFile -PathType Leaf)) {
            throw "Installed runtime missing '$Relative'."
        }
        $StagedHash = (Get-FileHash -LiteralPath $StagedFile.FullName -Algorithm SHA256).Hash
        $InstalledHash = (Get-FileHash -LiteralPath $InstalledFile -Algorithm SHA256).Hash
        if ($StagedHash -ne $InstalledHash) {
            throw "Installed runtime hash mismatch for '$Relative'."
        }
    }
    if ((Get-FileHash -LiteralPath $StagedLoader -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $TargetLoader -Algorithm SHA256).Hash) {
        throw 'Installed loader hash mismatch.'
    }

    $DevelopmentLoaders = @(Get-ChildItem -LiteralPath $PluginsPath -File -Filter '*bom*loader.rb' | Select-Object -ExpandProperty Name)
    Write-Output 'SKETCHUP EXTENSION INSTALL: READY'
    Write-Output "Installed extension path: $PluginsPath"
    Write-Output "Installed loader: $TargetLoader"
    Write-Output "Installed build SHA: $CommitSha"
    Write-Output "Recoverable backup: $BackupPath"
    Write-Output "BOM-related loaders present: $($DevelopmentLoaders -join ', ')"
    $InstallCompleted = $true
} catch {
    if (-not $InstallCompleted -and (Test-Path -LiteralPath $BackupPath)) {
        Assert-ChildPath -Path $TargetLoader -Parent $PluginsPath
        Assert-ChildPath -Path $TargetRuntime -Parent $PluginsPath
        if (Test-Path -LiteralPath $TargetLoader) {
            Remove-Item -LiteralPath $TargetLoader -Force
        }
        if (Test-Path -LiteralPath $TargetRuntime) {
            Remove-Item -LiteralPath $TargetRuntime -Recurse -Force
        }
        $BackupLoader = Join-Path $BackupPath 'bom_engine_loader.rb'
        $BackupRuntime = Join-Path $BackupPath 'bom_engine'
        if (Test-Path -LiteralPath $BackupLoader) {
            Move-Item -LiteralPath $BackupLoader -Destination $TargetLoader
        }
        if (Test-Path -LiteralPath $BackupRuntime) {
            Move-Item -LiteralPath $BackupRuntime -Destination $TargetRuntime
        }
    }
    throw
} finally {
    if (Test-Path -LiteralPath $TemporaryRoot) {
        Assert-ChildPath -Path $TemporaryRoot -Parent ([System.IO.Path]::GetTempPath())
        Remove-Item -LiteralPath $TemporaryRoot -Recurse -Force
    }
}
