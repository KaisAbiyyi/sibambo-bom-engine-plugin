$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'compare_native_export_receipts.ps1'
$root = Join-Path 'D:\projects\sibambo\scratch\perf-gpu-00\offline-tests' ('joint-receipt-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$source = 'a' * 64
$before = Join-Path $root 'before.json'
$after = Join-Path $root 'after.json'

function WriteFixture([string]$path, [string]$sourceSha, [int]$wall, [int]$candidate) {
  $trace = [ordered]@{
    schema = 'sibambo-performance-trace-v1'; enabled = $true; status = 'error'; total_wall_ms = $wall
    metadata = [ordered]@{
      source = [ordered]@{ sha256 = $sourceSha; bytes = 1000 }
      engine = 'e4'; profile = 'exact'; producer_source_sha256 = 'b' * 64
      size_gate = [ordered]@{
        best_candidate_bytes = $candidate
        dominant_sections = @([ordered]@{ name = 'textures'; stored_bytes = $candidate - 100 })
        largest_texture_decisions = @([ordered]@{
          bytes = 500; width_px = 10; height_px = 10; selected = 'staged_png'
          reason = 'native_jpeg_pixel_mismatch'; semantic_fallback = 'time_budget_exceeded'
        })
      }
    }
    counters = [ordered]@{ texture_optimizer_total_ms = $wall * 0.9; texture_semantic_verify_timeouts = 1 }
    stages = @()
    error_message = 'size gate fail'
  }
  $trace | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $path -Encoding UTF8
}

WriteFixture $before $source 5000 1500
WriteFixture $after $source 4000 1700
$gpuPath = Join-Path $root 'gpu.json'
@{schema = 'sibambo-gpu-export-final-v1'; samples = 3
  trace_receipt = @{sha256 = (Get-FileHash -LiteralPath $before -Algorithm SHA256).Hash.ToLowerInvariant()}
  metrics = @{max_logical_cpu_percent=100; sketchup_process_cpu_seconds_delta=2}
  adapter_luid_mapping_verified = $false; causal_attribution = 'NOT_ESTABLISHED'
} | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $gpuPath -Encoding UTF8

$positive = Join-Path $root 'result-pass'
& $script -BeforeTrace $before -AfterTrace $after -GpuFinal $gpuPath -OutputDirectory $positive | Out-Null
$result = Get-Content -LiteralPath (Join-Path $positive 'joint-evidence.json') -Raw | ConvertFrom-Json
if ($result.comparison.wall_delta_ms -ne -1000 -or $result.comparison.candidate_bytes_delta -ne 200 -or
    $result.comparison.after_actual_export_qualified -ne $false -or $result.gpu_before.before_trace_sha256_verified -ne $true) {
  throw 'Valid comparison must preserve delta, GPU SHA binding and unqualified acceptance.'
}

# A candidate from a different input must never be called a before/after result.
WriteFixture $after ('c' * 64) 4000 1700
$rejected = $false
try {
  & $script -BeforeTrace $before -AfterTrace $after -OutputDirectory (Join-Path $root 'result-mismatch') | Out-Null
} catch {
  $rejected = $_.Exception.Message -match 'source_sha256 differs'
}
if (-not $rejected) { throw 'Different source SHA was not rejected.' }

# A moved/mismatched diagnostic receipt must never be silently accepted.
WriteFixture $after $source 4000 1700
$gpu = Get-Content -LiteralPath $gpuPath -Raw | ConvertFrom-Json
$gpu.trace_receipt.sha256 = 'f' * 64
$gpu | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $gpuPath -Encoding UTF8
$rejected = $false
try {
  & $script -BeforeTrace $before -AfterTrace $after -GpuFinal $gpuPath -OutputDirectory (Join-Path $root 'result-bad-gpu') | Out-Null
} catch {
  $rejected = $_.Exception.Message -match 'not bound to the before export trace SHA'
}
if (-not $rejected) { throw 'Unbound GPU receipt was not rejected.' }

Write-Output 'PASS: matching native receipts, differing source rejection, GPU hash mismatch rejection'
