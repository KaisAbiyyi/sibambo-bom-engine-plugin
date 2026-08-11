param(
    [ValidateSet('Plugin', 'CleanRc', 'AppearanceRc', 'CompleteRc')]
    [string]$Target = 'Plugin'
)

$ErrorActionPreference = 'Stop'

$PluginDir = $PSScriptRoot
$StagingDir = Join-Path ([System.IO.Path]::GetTempPath()) "bom-engine-rbz-$([guid]::NewGuid())"

function Remove-TestsFromStaging {
    param(
        [string]$Root,
        [string]$RuntimeFolder
    )

    $TestsPath = Join-Path $Root "$RuntimeFolder\tests"
    if (Test-Path -LiteralPath $TestsPath) {
        Remove-Item -LiteralPath $TestsPath -Recurse -Force
    }
}

function Compress-Rbz {
    param(
        [string]$Source,
        [string]$Destination
    )

    $ZipPath = [System.IO.Path]::ChangeExtension($Destination, '.zip')
    if (Test-Path -LiteralPath $ZipPath) {
        Remove-Item -LiteralPath $ZipPath -Force
    }
    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Force
    }
    Compress-Archive -Path (Join-Path $Source '*') -DestinationPath $ZipPath -CompressionLevel Optimal
    Move-Item -LiteralPath $ZipPath -Destination $Destination
}

function Write-Utf8NoBom {
    param(
        [string]$Path,
        [string]$Content
    )

    [System.IO.File]::WriteAllText(
        $Path,
        $Content,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Expand-Template {
    param(
        [string]$TemplatePath,
        [string]$OutputPath,
        [hashtable]$Values
    )

    $Content = Get-Content -Raw -LiteralPath $TemplatePath
    foreach ($Entry in $Values.GetEnumerator()) {
        $Content = $Content.Replace("{{$($Entry.Key)}}", $Entry.Value)
    }
    Write-Utf8NoBom -Path $OutputPath -Content $Content
}

function Assert-CleanPackage {
    param([string]$Path)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $Archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $Entries = @($Archive.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
        $Required = @(
            'bom_engine_clean_loader.rb',
            'bom_engine_clean/clean_analysis.rb',
            'bom_engine_clean/clean_analysis/sketchup_entry.rb',
            'bom_engine_clean/clean_analysis/exporter.rb',
            'bom_engine_clean/semantic_labeler.rb',
            'bom_engine_clean/semantic_v2/identity_coordinator.rb',
            'bom_engine_clean/semantic_v2/extractor.rb'
        )
        $Missing = @($Required | Where-Object { $Entries -notcontains $_ })
        if ($Missing.Count -gt 0) {
            throw "RBZ is missing required runtime files: $($Missing -join ', ')"
        }
        $Forbidden = @($Entries | Where-Object {
            $_ -match '(^|/)(tests?|fixtures?)(/|$)' -or
            $_ -match '\.(skp|tmp|dump|prof|log)$' -or
            $_ -match '(^|/)\.git(/|$)'
        })
        if ($Forbidden.Count -gt 0) {
            throw "RBZ contains development files: $($Forbidden -join ', ')"
        }
        $Oversized = @($Archive.Entries | Where-Object { $_.Length -gt 10MB })
        if ($Oversized.Count -gt 0) {
            throw "RBZ contains unexpectedly large files: $($Oversized.FullName -join ', ')"
        }
    } finally {
        $Archive.Dispose()
    }

    $Extracted = Join-Path ([System.IO.Path]::GetTempPath()) "bom-engine-rbz-check-$([guid]::NewGuid())"
    try {
        [System.IO.Compression.ZipFile]::ExtractToDirectory($Path, $Extracted)
        $RuntimeFiles = Get-ChildItem -LiteralPath $Extracted -File -Recurse
        $DevelopmentPath = $RuntimeFiles | Select-String -Pattern 'D:/projects/', 'C:/Users/' -SimpleMatch
        if ($DevelopmentPath) {
            throw 'RBZ contains an absolute development path.'
        }
        $RubyFiles = $RuntimeFiles | Where-Object { $_.Extension -eq '.rb' }
        foreach ($RubyFile in $RubyFiles) {
            $Source = Get-Content -Raw -LiteralPath $RubyFile.FullName
            $Requires = [regex]::Matches(
                $Source,
                "require_relative\s+['`"]([^'`"]+)['`"]"
            )
            foreach ($Require in $Requires) {
                $RelativePath = $Require.Groups[1].Value.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
                $Resolved = [System.IO.Path]::GetFullPath(
                    (Join-Path $RubyFile.DirectoryName $RelativePath)
                )
                if ([System.IO.Path]::GetExtension($Resolved) -eq '') {
                    $Resolved = "$Resolved.rb"
                }
                if (-not (Test-Path -LiteralPath $Resolved -PathType Leaf)) {
                    throw "Unresolved packaged require_relative in $($RubyFile.Name): $RelativePath"
                }
            }
        }
    } finally {
        if (Test-Path -LiteralPath $Extracted) {
            Remove-Item -LiteralPath $Extracted -Recurse -Force
        }
    }
}

try {
    New-Item -ItemType Directory -Path $StagingDir | Out-Null
    $RuntimeFolder = if ($Target -eq 'Plugin') { 'bom_engine' } else { 'bom_engine_clean' }
    Copy-Item `
        -LiteralPath (Join-Path $PluginDir 'bom_engine') `
        -Destination (Join-Path $StagingDir $RuntimeFolder) `
        -Recurse
    Remove-TestsFromStaging -Root $StagingDir -RuntimeFolder $RuntimeFolder

    if ($Target -eq 'Plugin') {
        $Version = '3.0.0'
        $RootDir = Split-Path -Parent $PluginDir
        $OutputPath = Join-Path $RootDir "bom_engine_plugin_v$Version.rbz"
        Copy-Item -LiteralPath (Join-Path $PluginDir 'bom_engine_loader.rb') -Destination $StagingDir
        Compress-Rbz -Source $StagingDir -Destination $OutputPath
        Write-Output "Built: $OutputPath"
        return
    }

    $Commit = (& git -C $PluginDir rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $Commit -notmatch '^[0-9a-f]{40}$') {
        throw 'A valid source Git commit is required for a clean release candidate.'
    }
    $ShortSha = $Commit.Substring(0, 7)
    $PackageName = switch ($Target) {
        'AppearanceRc' { "bom_engine_clean_v1-appearance-rc-$ShortSha" }
        'CompleteRc' { "bom_engine_clean_v1-complete-rc-$ShortSha" }
        default { "bom_engine_clean_v1-rc-$ShortSha" }
    }
    $DistRoot = Join-Path $PluginDir 'dist'
    $OutputDir = Join-Path $DistRoot $PackageName
    $ResolvedDistRoot = [System.IO.Path]::GetFullPath($DistRoot)
    $ResolvedOutputDir = [System.IO.Path]::GetFullPath($OutputDir)
    if (-not $ResolvedOutputDir.StartsWith($ResolvedDistRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to build outside the repository dist directory.'
    }
    if (Test-Path -LiteralPath $OutputDir) {
        Remove-Item -LiteralPath $OutputDir -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

    Copy-Item -LiteralPath (Join-Path $PluginDir 'bom_engine_clean_loader.rb') -Destination $StagingDir
    $RbzPath = Join-Path $OutputDir "$PackageName.rbz"
    Compress-Rbz -Source $StagingDir -Destination $RbzPath
    Assert-CleanPackage -Path $RbzPath

    $TemplateValues = @{
        PACKAGE_NAME = $PackageName
        GIT_COMMIT = $Commit
    }
    $InstallTemplate = switch ($Target) {
        'AppearanceRc' { 'release\appearance\INSTALL.template.md' }
        'CompleteRc' { 'release\complete\INSTALL.template.md' }
        default { 'release\INSTALL.template.md' }
    }
    $AcceptanceTemplate = switch ($Target) {
        'AppearanceRc' { 'release\appearance\MANUAL_ACCEPTANCE.template.md' }
        'CompleteRc' { 'release\complete\MANUAL_ACCEPTANCE.template.md' }
        default { 'release\MANUAL_ACCEPTANCE.template.md' }
    }
    Expand-Template `
        -TemplatePath (Join-Path $PluginDir $InstallTemplate) `
        -OutputPath (Join-Path $OutputDir 'INSTALL.md') `
        -Values $TemplateValues
    Expand-Template `
        -TemplatePath (Join-Path $PluginDir $AcceptanceTemplate) `
        -OutputPath (Join-Path $OutputDir 'MANUAL_ACCEPTANCE.md') `
        -Values $TemplateValues
    if ($Target -eq 'AppearanceRc') {
        Expand-Template `
            -TemplatePath (Join-Path $PluginDir 'release\appearance\APPEARANCE_CONTRACT.template.md') `
            -OutputPath (Join-Path $OutputDir 'APPEARANCE_CONTRACT.md') `
            -Values $TemplateValues
    }
    if ($Target -eq 'CompleteRc') {
        Expand-Template `
            -TemplatePath (Join-Path $PluginDir 'release\complete\CLEANV1_CONTRACT.template.md') `
            -OutputPath (Join-Path $OutputDir 'CLEANV1_CONTRACT.md') `
            -Values $TemplateValues
        Expand-Template `
            -TemplatePath (Join-Path $PluginDir 'release\complete\COVERAGE_GUIDE.template.md') `
            -OutputPath (Join-Path $OutputDir 'COVERAGE_GUIDE.md') `
            -Values $TemplateValues
    }

    $VersionText = @"
format:
    bom_engine_clean_v1

version:
    1.0.0

release status:
    $(if ($Target -eq 'AppearanceRc') { 'APPEARANCE RELEASE CANDIDATE — REQUIRES SKETCHUP ACCEPTANCE' } else { 'RELEASE CANDIDATE — REQUIRES SKETCHUP ACCEPTANCE' })

git commit:
    $Commit

base handoff commit:
    $(if ($Target -eq 'AppearanceRc') { 'd611d59b4ac9fdb7c4b785cfd4ae072e418e67a9' } else { '72af3c2ef4b47bdbda8e8504a84e9ef3b651df76' })
"@
    if ($Target -eq 'CompleteRc') {
        $VersionText = [regex]::Replace(
            $VersionText,
            'release status:\r?\n\s+[^\r\n]+',
            "release status:`r`n    COMPLETENESS RELEASE CANDIDATE - REQUIRES USER SKETCHUP ACCEPTANCE"
        )
        $VersionText = [regex]::Replace(
            $VersionText,
            'base handoff commit:\r?\n\s+[0-9a-f]+',
            "base handoff commit:`r`n    52f405c7b606700cc354247e29259549cfa57a28"
        )
    }
    Write-Utf8NoBom -Path (Join-Path $OutputDir 'VERSION.txt') -Content $VersionText

    $ChecksumTargets = @(
        $RbzPath,
        (Join-Path $OutputDir 'INSTALL.md'),
        (Join-Path $OutputDir 'MANUAL_ACCEPTANCE.md'),
        (Join-Path $OutputDir 'VERSION.txt')
    )
    if ($Target -eq 'AppearanceRc') {
        $ChecksumTargets += (Join-Path $OutputDir 'APPEARANCE_CONTRACT.md')
    }
    if ($Target -eq 'CompleteRc') {
        $ChecksumTargets += (Join-Path $OutputDir 'CLEANV1_CONTRACT.md')
        $ChecksumTargets += (Join-Path $OutputDir 'COVERAGE_GUIDE.md')
    }
    $ChecksumLines = $ChecksumTargets | ForEach-Object {
        $Hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $_).Hash.ToLowerInvariant()
        "$Hash  $([System.IO.Path]::GetFileName($_))"
    }
    Write-Utf8NoBom `
        -Path (Join-Path $OutputDir 'CHECKSUMS.sha256') `
        -Content (($ChecksumLines -join "`n") + "`n")

    $HandoffPath = Join-Path $DistRoot "$PackageName-handoff.zip"
    if (Test-Path -LiteralPath $HandoffPath) {
        Remove-Item -LiteralPath $HandoffPath -Force
    }
    Compress-Archive -LiteralPath $OutputDir -DestinationPath $HandoffPath -CompressionLevel Optimal
    $HandoffHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $HandoffPath).Hash.ToLowerInvariant()
    Write-Utf8NoBom `
        -Path "$HandoffPath.sha256" `
        -Content "$HandoffHash  $([System.IO.Path]::GetFileName($HandoffPath))`n"

    Write-Output "Built: $RbzPath"
    Write-Output "Verified: loader, runtime closure, exclusions, and development paths"
    Write-Output "Built: $HandoffPath"
    Write-Output "Handoff SHA256: $HandoffHash"
} finally {
    if (Test-Path -LiteralPath $StagingDir) {
        Remove-Item -LiteralPath $StagingDir -Recurse -Force
    }
}
