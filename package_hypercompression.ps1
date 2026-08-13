param(
    [string]$CommitSha = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ProjectRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)
if ([string]::IsNullOrWhiteSpace($CommitSha)) {
    $CommitSha = (& git -C $ProjectRoot rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to resolve the current Git commit.'
    }
}
if ($CommitSha -notmatch '^[0-9a-fA-F]{40}$') {
    throw "CommitSha must resolve to a full 40-character Git SHA. Received '$CommitSha'."
}
$CommitSha = $CommitSha.ToLowerInvariant()
$ShortSha = $CommitSha.Substring(0, 12)
$ReleaseName = "bom_engine-hypercompression-rc-$ShortSha"
$DistRoot = [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot 'dist'))
$HandoffDirectory = [System.IO.Path]::GetFullPath((Join-Path $DistRoot $ReleaseName))
$OuterZip = [System.IO.Path]::GetFullPath((Join-Path $DistRoot "$ReleaseName.zip"))
$TemporaryRoot = [System.IO.Path]::GetFullPath((Join-Path ([System.IO.Path]::GetTempPath()) "bomc-package-$([guid]::NewGuid())"))
$SourceArchive = Join-Path $TemporaryRoot 'source.zip'
$StagingDirectory = Join-Path $TemporaryRoot 'staging'

function Assert-OwnedPath {
    param([string]$Path, [string]$Parent)
    $ResolvedPath = [System.IO.Path]::GetFullPath($Path)
    $ResolvedParent = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
    if (-not $ResolvedPath.StartsWith($ResolvedParent, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing filesystem operation outside owned directory: $ResolvedPath"
    }
}

function Remove-OwnedTree {
    param([string]$Path, [string]$Parent)
    Assert-OwnedPath -Path $Path -Parent $Parent
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

function New-DeterministicZip {
    param(
        [string]$SourceDirectory,
        [string]$DestinationPath,
        [string]$RootPrefix = ''
    )
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $DestinationPath) {
        Remove-Item -LiteralPath $DestinationPath -Force
    }
    $SourceFull = [System.IO.Path]::GetFullPath($SourceDirectory).TrimEnd('\') + '\'
    $Files = Get-ChildItem -LiteralPath $SourceDirectory -File -Recurse | Sort-Object FullName
    $Archive = [System.IO.Compression.ZipFile]::Open($DestinationPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($File in $Files) {
            $Relative = $File.FullName.Substring($SourceFull.Length).Replace('\', '/')
            if (-not [string]::IsNullOrEmpty($RootPrefix)) {
                $Relative = $RootPrefix.TrimEnd('/') + '/' + $Relative
            }
            $Entry = $Archive.CreateEntry($Relative, [System.IO.Compression.CompressionLevel]::Optimal)
            $Entry.LastWriteTime = [DateTimeOffset]::new(2026, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
            $Input = [System.IO.File]::OpenRead($File.FullName)
            $Output = $Entry.Open()
            try {
                $Input.CopyTo($Output)
            } finally {
                $Output.Dispose()
                $Input.Dispose()
            }
        }
    } finally {
        $Archive.Dispose()
    }
}

try {
    New-Item -ItemType Directory -Path $TemporaryRoot, $StagingDirectory, $DistRoot -Force | Out-Null
    Remove-OwnedTree -Path $HandoffDirectory -Parent $DistRoot
    if (Test-Path -LiteralPath $OuterZip) {
        Assert-OwnedPath -Path $OuterZip -Parent $DistRoot
        Remove-Item -LiteralPath $OuterZip -Force
    }

    $ArchivePaths = @(
        'bom_engine',
        'bom_engine_hypercompression_loader.rb',
        'BOM_COMPILED_FORMAT.md',
        'BENCHMARK_REPORT.md',
        'MANUAL_ACCEPTANCE.md'
    )
    & git -C $ProjectRoot archive --format=zip --output=$SourceArchive $CommitSha -- $ArchivePaths
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $SourceArchive)) {
        throw "git archive failed for commit $CommitSha."
    }
    Expand-Archive -LiteralPath $SourceArchive -DestinationPath $StagingDirectory

    $RuntimeTests = Join-Path $StagingDirectory 'bom_engine\tests'
    $RuntimeTools = Join-Path $StagingDirectory 'bom_engine\tools'
    $GraphCache = Join-Path $StagingDirectory 'bom_engine\graphify-out'
    Remove-OwnedTree -Path $RuntimeTests -Parent $StagingDirectory
    Remove-OwnedTree -Path $RuntimeTools -Parent $StagingDirectory
    Remove-OwnedTree -Path $GraphCache -Parent $StagingDirectory

    $LoaderSource = Join-Path $StagingDirectory 'bom_engine_hypercompression_loader.rb'
    $LoaderDestination = Join-Path $StagingDirectory 'bom_engine_loader.rb'
    Move-Item -LiteralPath $LoaderSource -Destination $LoaderDestination

    New-Item -ItemType Directory -Path $HandoffDirectory | Out-Null
    foreach ($Document in @('BOM_COMPILED_FORMAT.md', 'BENCHMARK_REPORT.md', 'MANUAL_ACCEPTANCE.md')) {
        $SourceDocument = Join-Path $StagingDirectory $Document
        Copy-Item -LiteralPath $SourceDocument -Destination $HandoffDirectory
        Remove-Item -LiteralPath $SourceDocument -Force
    }

    $RbzName = "$ReleaseName.rbz"
    $RbzPath = Join-Path $HandoffDirectory $RbzName
    New-DeterministicZip -SourceDirectory $StagingDirectory -DestinationPath $RbzPath

    $VersionLines = @(
        'plugin_version=3.2.0-rc.1',
        'compiled_format=BOMC 1.0',
        "commit_sha=$CommitSha",
        'profile_default=production'
    )
    [System.IO.File]::WriteAllLines((Join-Path $HandoffDirectory 'VERSION.txt'), $VersionLines, [System.Text.UTF8Encoding]::new($false))

    $ChecksumTargets = Get-ChildItem -LiteralPath $HandoffDirectory -File | Where-Object { $_.Name -ne 'CHECKSUMS.sha256' } | Sort-Object Name
    $ChecksumLines = $ChecksumTargets | ForEach-Object {
        $Hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        "$Hash  $($_.Name)"
    }
    [System.IO.File]::WriteAllLines((Join-Path $HandoffDirectory 'CHECKSUMS.sha256'), $ChecksumLines, [System.Text.UTF8Encoding]::new($false))

    New-DeterministicZip -SourceDirectory $HandoffDirectory -DestinationPath $OuterZip -RootPrefix $ReleaseName

    $Archive = [System.IO.Compression.ZipFile]::OpenRead($RbzPath)
    try {
        $Names = @($Archive.Entries | ForEach-Object { $_.FullName })
    } finally {
        $Archive.Dispose()
    }
    foreach ($Required in @(
        'bom_engine_loader.rb',
        'bom_engine/bomc_extension.rb',
        'bom_engine/bomc_format.rb',
        'bom_engine/bomc_codecs.rb',
        'bom_engine/bomc_model_adapter.rb',
        'bom_engine/bomc_writer.rb',
        'bom_engine/bomc_decoder.rb'
    )) {
        if ($Names -notcontains $Required) {
            throw "RBZ validation failed: missing $Required."
        }
    }
    if ($Names | Where-Object { $_ -match '(^|/)tests/|(^|/)tools/|graphify-out|\.skp$' }) {
        throw 'RBZ validation failed: development-only files are present.'
    }

    $RbzSha = (Get-FileHash -LiteralPath $RbzPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $OuterSha = (Get-FileHash -LiteralPath $OuterZip -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Output "Handoff directory: $HandoffDirectory"
    Write-Output "RBZ: $RbzPath"
    Write-Output "RBZ SHA256: $RbzSha"
    Write-Output "Outer ZIP: $OuterZip"
    Write-Output "Outer ZIP SHA256: $OuterSha"
} finally {
    if (Test-Path -LiteralPath $TemporaryRoot) {
        Remove-OwnedTree -Path $TemporaryRoot -Parent ([System.IO.Path]::GetTempPath())
    }
}
