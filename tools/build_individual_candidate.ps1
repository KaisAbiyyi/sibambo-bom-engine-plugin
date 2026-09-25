param(
  [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$producer = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$workspace = Split-Path -Parent $producer
if (-not $OutputDirectory) {
  $date = Get-Date -Format 'yyyy-MM-dd'
  $OutputDirectory = Join-Path $workspace "outputs\$date-current-candidates\individual-bomc"
}
$destination = [System.IO.Path]::GetFullPath($OutputDirectory)
if (-not $destination.StartsWith($workspace + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
  throw "Output directory must stay inside the Sibambo workspace: $destination"
}

$loader = Join-Path $producer 'bom_engine_loader.rb'
if (-not (Test-Path -LiteralPath $loader -PathType Leaf)) { throw 'Missing individual plugin loader' }
$runtime = Join-Path $producer 'bom_engine'
if (-not (Test-Path -LiteralPath $runtime -PathType Container)) { throw 'Missing bom_engine runtime directory' }

$files = [System.Collections.Generic.List[object]]::new()
$files.Add([pscustomobject]@{ source = $loader; entry = 'bom_engine_loader.rb' })
foreach ($file in Get-ChildItem -LiteralPath $runtime -Recurse -File) {
  $relative = $file.FullName.Substring($producer.Length + 1).Replace('\', '/')
  if ($relative -match '^bom_engine/(tests|graphify-out)/' -or $relative -eq 'bom_engine/BUILD_SHA.txt') { continue }
  $files.Add([pscustomobject]@{ source = $file.FullName; entry = $relative })
}
$ordered = @($files | Sort-Object entry)
$rows = @($ordered | ForEach-Object {
  "$($_.entry)`t$((Get-FileHash -LiteralPath $_.source -Algorithm SHA256).Hash.ToLowerInvariant())"
})
$treeBytes = [System.Text.Encoding]::UTF8.GetBytes(($rows -join "`n") + "`n")
$treeSha = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($treeBytes)).ToLowerInvariant()
$baseCommit = (& git -C $producer rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $baseCommit -notmatch '^[0-9a-f]{40}$') { throw 'Cannot resolve producer base commit' }

New-Item -ItemType Directory -Path $destination -Force | Out-Null
$name = "Sibambo-BOMC-Engine-v1.2.0-tree-$($treeSha.Substring(0, 12))"
$package = Join-Path $destination "$name.rbz"
$partial = Join-Path $destination "$name.rbz.part"
$manifest = Join-Path $destination "$name.manifest.json"
foreach ($path in @($package, $partial, $manifest)) {
  if (Test-Path -LiteralPath $path) { throw "Refusing to overwrite existing output: $path" }
}

$zip = [System.IO.Compression.ZipFile]::Open($partial, [System.IO.Compression.ZipArchiveMode]::Create)
try {
  foreach ($file in $ordered) {
    $entry = $zip.CreateEntry($file.entry, [System.IO.Compression.CompressionLevel]::Optimal)
    $entry.LastWriteTime = [System.DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [System.TimeSpan]::Zero)
    $inputStream = [System.IO.File]::OpenRead($file.source)
    $outputStream = $entry.Open()
    try { $inputStream.CopyTo($outputStream) }
    finally { $outputStream.Dispose(); $inputStream.Dispose() }
  }
  $identity = $zip.CreateEntry('bom_engine/BUILD_SHA.txt', [System.IO.Compression.CompressionLevel]::Optimal)
  $identity.LastWriteTime = [System.DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [System.TimeSpan]::Zero)
  $stream = $identity.Open()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes("$treeSha`n")
    $stream.Write($bytes, 0, $bytes.Length)
  } finally { $stream.Dispose() }
} finally { $zip.Dispose() }

$archive = [System.IO.Compression.ZipFile]::OpenRead($partial)
try {
  if ($archive.Entries.Count -ne ($ordered.Count + 1)) { throw 'Archive entry count mismatch' }
  if (-not ($archive.Entries | Where-Object FullName -eq 'bom_engine/BUILD_SHA.txt')) {
    throw 'Archive missing source-tree identity'
  }
} finally { $archive.Dispose() }
Move-Item -LiteralPath $partial -Destination $package -ErrorAction Stop
$packageSha = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash.ToLowerInvariant()

[ordered]@{
  schemaVersion = 'sibambo-individual-candidate-v1'
  status = 'candidate_pending_cross_model_validation'
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  producerPath = $producer
  baseCommitSha = $baseCommit
  sourceTreeSha256 = $treeSha
  identityMeaning = 'SHA-256 of sorted runtime path and file-hash rows; BUILD_SHA.txt contains this content identity, not Git HEAD'
  fileCount = $ordered.Count
  package = [System.IO.Path]::GetFileName($package)
  packageSha256 = $packageSha
  installed = $false
  sketchUpRuntimeTested = $false
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifest -Encoding utf8

Write-Output "Individual candidate: $package"
Write-Output "Manifest: $manifest"
Write-Output "Source tree SHA-256: $treeSha"
Write-Output "Package SHA-256: $packageSha"
