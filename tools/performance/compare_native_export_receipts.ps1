# Compare two immutable SketchUp exporter traces without running SketchUp.
# The result is a diagnostic only; it cannot qualify Exact fidelity or a release.
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$BeforeTrace,
  [Parameter(Mandatory=$true)][string]$AfterTrace,
  [string]$GpuFinal,
  [Parameter(Mandatory=$true)][string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$destination = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $destination.StartsWith('D:\', [StringComparison]::OrdinalIgnoreCase)) {
  throw 'Sibambo evidence output must remain on D:.'
}
if (Test-Path -LiteralPath $destination) {
  throw "Refusing to overwrite existing evidence directory: $destination"
}
$temp = 'D:\projects\sibambo\scratch\perf-gpu-00\temp'
[void][IO.Directory]::CreateDirectory($temp)
$env:TEMP = $temp
$env:TMP = $temp

function ReadTrace([string]$path) {
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Trace missing: $path" }
  $raw = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
  if ($raw.schema -ne 'sibambo-performance-trace-v1' -or $raw.enabled -ne $true) {
    throw "Invalid enabled export trace schema: $path"
  }
  $source = $raw.metadata.source
  if (-not $source -or $source.sha256 -notmatch '^[0-9a-fA-F]{64}$' -or [long]$source.bytes -le 0) {
    throw "Missing saved source identity: $path"
  }
  $runtime = [string]$raw.metadata.producer_source_sha256
  if ($runtime -notmatch '^[0-9a-fA-F]{64}$') { throw "Missing producer identity: $path" }
  if ([double]$raw.total_wall_ms -le 0) { throw "Missing wall duration: $path" }

  $size = $null
  $texture = $null
  $largest = @()
  if ($raw.metadata.PSObject.Properties['size_gate'] -and $raw.metadata.size_gate) {
    $gate = $raw.metadata.size_gate
    if ($null -ne $gate.best_candidate_bytes) { $size = [long]$gate.best_candidate_bytes }
    $section = @($gate.dominant_sections | Where-Object { $_.name -eq 'textures' })
    if ($section.Count -gt 0) { $texture = [long]$section[0].stored_bytes }
    $largest = @($gate.largest_texture_decisions | Select-Object -First 12 | ForEach-Object {
      [ordered]@{ bytes = [long]$_.bytes; width_px = [int]$_.width_px
        height_px = [int]$_.height_px; selected = [string]$_.selected
        reason = [string]$_.reason; semantic_fallback = [string]$_.semantic_fallback }
    })
  }
  if ($null -eq $size -and $raw.error_message -match '\bbest=(\d+)') { $size = [long]$Matches[1] }
  if ($null -eq $texture -and $raw.error_message -match '\btextures=(\d+)') { $texture = [long]$Matches[1] }
  $stages = @($raw.stages)
  $optimizer = $null
  if ($raw.counters -and $null -ne $raw.counters.texture_optimizer_total_ms) {
    $optimizer = [double]$raw.counters.texture_optimizer_total_ms
  } else {
    $optimizer = (@($stages | Where-Object { $_.name -eq 'texture_optimizer' }) |
      Measure-Object duration_ms -Sum).Sum
  }
  [ordered]@{
    sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    source_sha256 = $source.sha256.ToLowerInvariant()
    source_bytes = [long]$source.bytes
    producer_source_sha256 = $runtime.ToLowerInvariant()
    engine = [string]$raw.metadata.engine
    profile = [string]$raw.metadata.profile
    status = [string]$raw.status
    wall_ms = [double]$raw.total_wall_ms
    optimizer_ms = [double]$optimizer
    candidate_bytes = $size
    texture_section_bytes = $texture
    published_output_proven = $false
    semantic_timeouts = $(if ($raw.counters) { [int]$raw.counters.texture_semantic_verify_timeouts } else { 0 })
    largest_texture_decisions = $largest
  }
}

$before = ReadTrace $BeforeTrace
$after = ReadTrace $AfterTrace
foreach ($field in @('source_sha256','source_bytes','engine','profile')) {
  if ($before[$field] -ne $after[$field]) { throw "Refusing incomparable traces: $field differs" }
}
$gpu = $null
if ($GpuFinal) {
  if (-not (Test-Path -LiteralPath $GpuFinal -PathType Leaf)) { throw 'GPU Final receipt missing.' }
  $record = Get-Content -LiteralPath $GpuFinal -Raw | ConvertFrom-Json
  if ($record.schema -ne 'sibambo-gpu-export-final-v1' -or -not $record.trace_receipt -or
      $record.trace_receipt.sha256 -ne $before.sha256) {
    throw 'GPU Final receipt is not bound to the before export trace SHA.'
  }
  $gpu = [ordered]@{
    samples = [int]$record.samples
    before_trace_sha256_verified = $true
    max_logical_cpu_percent = $record.metrics.max_logical_cpu_percent
    sketchup_process_cpu_seconds_delta = $record.metrics.sketchup_process_cpu_seconds_delta
    gpu_luid_mapping_verified = [bool]$record.adapter_luid_mapping_verified
    causal_attribution = [string]$record.causal_attribution
  }
}
$wallDelta = $after.wall_ms - $before.wall_ms
$bytesDelta = $null
$bytesPercent = $null
if ($null -ne $before.candidate_bytes -and $null -ne $after.candidate_bytes -and $before.candidate_bytes -gt 0) {
  $bytesDelta = $after.candidate_bytes - $before.candidate_bytes
  $bytesPercent = [math]::Round(100.0 * $bytesDelta / $before.candidate_bytes, 3)
}
$report = [ordered]@{
  schema = 'sibambo-joint-export-native-evidence-v1'
  source_sha256 = $before.source_sha256
  source_bytes = $before.source_bytes
  engine = $before.engine
  profile = $before.profile
  before = $before
  after = $after
  comparison = [ordered]@{
    wall_delta_ms = [math]::Round($wallDelta,3)
    wall_delta_percent = [math]::Round(100.0 * $wallDelta / $before.wall_ms,3)
    candidate_bytes_delta = $bytesDelta
    candidate_bytes_delta_percent = $bytesPercent
    after_candidate_below_source = ($null -ne $after.candidate_bytes -and $after.candidate_bytes -lt $after.source_bytes)
    after_actual_export_qualified = $false
    repeatable_speedup_proven = $false
    exact_fidelity_readback_proven = $false
  }
  gpu_before = $gpu
  verdict = 'NATIVE_ACCEPTANCE_OPEN'
  note = 'Candidate bytes on failed runs are not published artifacts. Real source-matched Y and I outputs, independent Exact fidelity and repeats are required.'
}
[void][IO.Directory]::CreateDirectory($destination)
$output = Join-Path $destination 'joint-evidence.json'
$report | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $output -Encoding UTF8
Write-Output "Joint native evidence: $output"
