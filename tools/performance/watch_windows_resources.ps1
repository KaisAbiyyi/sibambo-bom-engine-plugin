# Windows owner-side resource sampler for native SketchUp conversion.
# Run in a separate PowerShell session before starting the export.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateRange(1, 2147483647)][int]$ProcessId,
    [string]$OutputPath = "D:\projects\sibambo\scratch\resource-traces\sketchup-$ProcessId-$(Get-Date -Format yyyyMMdd-HHmmss).jsonl",
    [ValidateRange(2, 30)][int]$IntervalSeconds = 3,
    [ValidateRange(1, 7200)][int]$DurationSeconds = 2400
)

$ErrorActionPreference = 'Stop'
$target = [IO.Path]::GetFullPath($OutputPath)
if (-not $target.StartsWith('D:\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Telemetry must be stored on D: ($target)."
}
$dir = [IO.Path]::GetDirectoryName($target)
[IO.Directory]::CreateDirectory($dir) | Out-Null
$env:TEMP = 'D:\projects\sibambo\scratch\resource-traces\temp'
$env:TMP = $env:TEMP
[IO.Directory]::CreateDirectory($env:TEMP) | Out-Null
if ([IO.File]::Exists($target)) { throw "Telemetry path already exists: $target" }

# One bundled PDH sample is materially cheaper than four separate Get-Counter
# calls. GPU Engine wildcard PDH costs ~4.5 seconds on the owner machine, so
# use the formatted Win32 GPU counter class (~0.6s measured) instead.
$counterPaths = @(
    '\Processor(*)\% Processor Time',
    '\Memory\Available MBytes',
    '\Memory\% Committed Bytes In Use',
    '\PhysicalDisk(_Total)\Disk Bytes/sec',
    '\PhysicalDisk(_Total)\Avg. Disk Queue Length'
)
$supported = [ordered]@{}
try {
    $null = Get-Counter -Counter $counterPaths -MaxSamples 1 -ErrorAction Stop
    $supported.cpu = $true
    $supported.memory = $true
    $supported.disk = $true
} catch {
    $supported.cpu = $false
    $supported.memory = $false
    $supported.disk = $false
}
try {
    $null = Get-CimInstance -ClassName Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -ErrorAction Stop
    $supported.gpu = $true
} catch {
    $supported.gpu = $false
}
$writer = [IO.StreamWriter]::new($target, $false, [Text.UTF8Encoding]::new($false))
$watch = [Diagnostics.Stopwatch]::StartNew()
try {
    $proc = Get-Process -Id $ProcessId -ErrorAction Stop
    $identity = [ordered]@{
        type = 'start'
        schema = 'sibambo-native-resource-sampler-v1'
        recorded_utc = [DateTimeOffset]::UtcNow.ToString('o')
        process_id = $ProcessId
        process_name = $proc.ProcessName
        process_start_utc = $proc.StartTime.ToUniversalTime().ToString('o')
        interval_seconds = $IntervalSeconds
        supported_counters = $supported
        gpu_metric = 'sum of Windows formatted GPU Engine utilization counters for PID; not normalized device utilization'
        drive_metric = 'all physical disks; no D: attribution without disk-to-volume mapping'
    }
    $writer.WriteLine(($identity | ConvertTo-Json -Depth 7 -Compress))
    $writer.Flush()
    $nextSample = 0.0
    while ($watch.Elapsed.TotalSeconds -lt $DurationSeconds) {
        if ($watch.Elapsed.TotalSeconds -lt $nextSample) {
            Start-Sleep -Milliseconds 100
            continue
        }
        $sampleWatch = [Diagnostics.Stopwatch]::StartNew()
        $samplerCpuStart = (Get-Process -Id $PID).TotalProcessorTime.TotalMilliseconds
        try {
            $proc = Get-Process -Id $ProcessId -ErrorAction Stop
            if ($proc.StartTime.ToUniversalTime().ToString('o') -ne $identity.process_start_utc) {
                throw 'Process ID was reused'
            }
        } catch {
            $writer.WriteLine((@{ type = 'end'; reason = 'process_exited_or_reused'; utc = [DateTimeOffset]::UtcNow.ToString('o') } | ConvertTo-Json -Compress))
            break
        }
        $row = [ordered]@{
            type = 'sample'
            utc = [DateTimeOffset]::UtcNow.ToString('o')
            elapsed_ms = [Math]::Round($watch.Elapsed.TotalMilliseconds, 1)
            process_cpu_seconds_total = [Math]::Round($proc.TotalProcessorTime.TotalSeconds, 3)
            process_working_set_bytes = [int64]$proc.WorkingSet64
            process_private_bytes = [int64]$proc.PrivateMemorySize64
            cpu_total_percent = $null
            cpu_per_core_percent = @{}
            ram_available_mb = $null
            ram_committed_percent = $null
            gpu_engine_percent_sum_for_pid = $null
            gpu_engine_breakdown_for_pid = @{}
            disk_total_bytes_per_second = $null
            disk_avg_queue_length = $null
            unavailable = @()
        }
        if ($supported.cpu) {
            try {
                $samples = @( (Get-Counter -Counter $counterPaths -MaxSamples 1 -ErrorAction Stop).CounterSamples )
                foreach ($counter in $samples) {
                    $path = $counter.Path.ToLowerInvariant()
                    $value = [double]$counter.CookedValue
                    if ([double]::IsNaN($value) -or [double]::IsInfinity($value)) { continue }
                    if ($path -match '\\processor\(_total\)') { $row.cpu_total_percent = [Math]::Round($value, 2) }
                    elseif ($path -match '\\processor\(([^)]+)\)') { $row.cpu_per_core_percent[$Matches[1]] = [Math]::Round($value, 2) }
                    elseif ($path -like '*available mbytes') { $row.ram_available_mb = [Math]::Round($value, 1) }
                    elseif ($path -like '*committed bytes in use') { $row.ram_committed_percent = [Math]::Round($value, 2) }
                    elseif ($path -like '*disk bytes/sec') { $row.disk_total_bytes_per_second = [Math]::Round($value, 0) }
                    elseif ($path -like '*avg. disk queue length') { $row.disk_avg_queue_length = [Math]::Round($value, 3) }
                }
            } catch {
                $row.unavailable += @('cpu','memory','disk')
            }
        } else {
            $row.unavailable += @('cpu','memory','disk')
        }
        if ($supported.gpu) {
            try {
                $gpuInstances = Get-CimInstance -ClassName Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -ErrorAction Stop
                $sum = 0.0
                foreach ($engine in $gpuInstances) {
                    if ($engine.Name -notmatch ("pid_" + $ProcessId + "_")) { continue }
                    $value = [double]$engine.UtilizationPercentage
                    if ([double]::IsNaN($value) -or [double]::IsInfinity($value)) { continue }
                    $row.gpu_engine_breakdown_for_pid[$engine.Name] = [Math]::Round($value, 2)
                    $sum += $value
                }
                $row.gpu_engine_percent_sum_for_pid = [Math]::Round($sum, 2)
            } catch { $row.unavailable += 'gpu' }
        } else {
            $row.unavailable += 'gpu'
        }
        $sampleWatch.Stop()
        $row.sampler_cpu_ms = [Math]::Round(
            (Get-Process -Id $PID).TotalProcessorTime.TotalMilliseconds - $samplerCpuStart, 2)
        $row.utc = [DateTimeOffset]::UtcNow.ToString('o')
        $row.elapsed_ms = [Math]::Round($watch.Elapsed.TotalMilliseconds, 1)
        $row.sample_overhead_ms = [Math]::Round($sampleWatch.Elapsed.TotalMilliseconds, 2)
        $writer.WriteLine(($row | ConvertTo-Json -Depth 8 -Compress))
        $writer.Flush()
        $nextSample = $watch.Elapsed.TotalSeconds + $IntervalSeconds
    }
} finally {
    $watch.Stop()
    $writer.Dispose()
}
Write-Output $target
