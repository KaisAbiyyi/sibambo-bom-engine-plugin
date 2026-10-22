# SIB-PERF-GPU-00: read-only Windows host telemetry. No SketchUp/driver setting changes.
# Run in Windows PowerShell 5.1; generated data stays on D:.
[CmdletBinding()]
param(
    [ValidateSet('Snapshot', 'Capture', 'Finalize')][string]$Mode = 'Snapshot',
    [ValidatePattern('^[A-Za-z0-9_-]{1,100}$')][string]$RunId = 'host_snapshot',
    [string]$OutputRoot = 'D:\projects\sibambo\scratch\perf-gpu-00',
    [ValidateRange(1, 1800)][int]$Samples = 10,
    [switch]$AllowIdleSmoke,
    [switch]$HostClaimConfirmed,
    [string]$SourceSkp,
    [string]$PackageRbz,
    [string]$InstallReceipt,
    [string]$StageReceipt,
    [string]$ArtifactPath,
    [ValidateSet('e2', 'e3', 'e4', 'unspecified')][string]$WireEngineId = 'unspecified',
    [ValidateSet('single', 'export_all')][string]$ExportMode = 'single',
    [ValidateSet('exact', 'visual', 'unspecified')][string]$Profile = 'unspecified',
    [ValidateSet('cold', 'warm', 'unspecified')][string]$Cache = 'unspecified',
    [ValidateSet('intel', 'nvidia', 'default', 'unverified')][string]$AdapterMode = 'unverified'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$resolvedRoot = [System.IO.Path]::GetFullPath($OutputRoot)
if (-not $resolvedRoot.StartsWith('D:\', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Sibambo diagnostic outputs must stay on D:.'
}
$runFolder = Join-Path $resolvedRoot $RunId
$temporary = 'D:\projects\sibambo\scratch\perf-gpu-00\temp'
[void][System.IO.Directory]::CreateDirectory($temporary)
$env:TEMP = $temporary
$env:TMP = $temporary

function FileIdentity([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing source/artifact: $Path" }
    $item = Get-Item -LiteralPath $Path
    return [ordered]@{
        path = $item.FullName
        bytes = [long]$item.Length
        sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function SaveJson([string]$Path, $Value) {
    $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function CaptureHost {
    $os = Get-CimInstance Win32_OperatingSystem
    $cpu = @(Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors, MaxClockSpeed)
    $video = @(Get-CimInstance Win32_VideoController | Select-Object Name, DriverVersion, PNPDeviceID, VideoProcessor)
    $display = @(Get-CimInstance Win32_DesktopMonitor -ErrorAction SilentlyContinue | Select-Object Name, PNPDeviceID)
    $sketchup = @(Get-Process -Name SketchUp -ErrorAction SilentlyContinue | Select-Object Id, Path, StartTime)
    $battery = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object BatteryStatus, EstimatedChargeRemaining)
    $install = $null
    if ($InstallReceipt) {
        $install = [ordered]@{ file = (FileIdentity $InstallReceipt); receipt = (Get-Content -LiteralPath $InstallReceipt -Raw | ConvertFrom-Json) }
    }
    $installedMarkers = @()
    if ($install -and $install.receipt.pluginsPath) {
        foreach ($suffix in @(
            'evolution_lineup\runtime\bom_engine\BUILD_SHA.txt',
            'evolution_lineup\engine_e4_bomc\bom_engine\BUILD_SHA.txt'
        )) {
            $markerPath = Join-Path $install.receipt.pluginsPath $suffix
            $marker = FileIdentity $markerPath
            $installedMarkers += [ordered]@{
                file = $marker
                source_tree_sha256 = (Get-Content -LiteralPath $markerPath -Raw).Trim()
                matches_install_receipt = ((Get-Content -LiteralPath $markerPath -Raw).Trim() -eq $install.receipt.sourceTreeSha256)
            }
        }
    }
    $preferences = @()
    $prefKey = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
    if (Test-Path $prefKey) {
        $properties = Get-ItemProperty -Path $prefKey
        $preferences = @($properties.PSObject.Properties | Where-Object { $_.Name -match 'sketchup' } | ForEach-Object {
            [ordered]@{ application = $_.Name; setting = [string]$_.Value }
        })
    }
    $power = (& powercfg.exe /getactivescheme 2>&1 | Out-String).Trim()
    return [ordered]@{
        schema = 'sibambo-windows-gpu-host-v1'; captured_utc = (Get-Date).ToUniversalTime().ToString('o')
        os = [ordered]@{ caption = $os.Caption; version = $os.Version; build = $os.BuildNumber }
        cpu = $cpu; graphics_adapters = $video; displays = $display
        memory_total_bytes = [long](Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
        battery = $battery; power_scheme = $power
        sketchup_processes = $sketchup; sketchup_gpu_preferences = $preferences
        input_skp = (FileIdentity $SourceSkp); package_rbz = (FileIdentity $PackageRbz)
        install_receipt = $install; installed_source_markers = $installedMarkers
        loaded_exporter_source_sha = $null
        loaded_exporter_source_verified = $false
        note = 'Installed files, package, and actual loaded SketchUp Ruby runtime are separate. Loaded runtime must be verified in SketchUp.'
    }
}

function GetProcessSnapshot {
    $result = @()
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^(SketchUp|dwm)$' })) {
        try {
            $threads = @($p.Threads | ForEach-Object {
                try { [ordered]@{ id = $_.Id; cpu_seconds = $_.TotalProcessorTime.TotalSeconds; state = $_.ThreadState.ToString() } } catch { }
            })
            $result += [ordered]@{
                pid = $p.Id; process = $p.ProcessName; cpu_seconds = $p.CPU
                working_set_bytes = [long]$p.WorkingSet64
                private_bytes = [long]$p.PrivateMemorySize64
                threads = $threads
            }
        } catch { }
    }
    return $result
}

function CounterSnapshot {
    # Read one synchronized performance-counter sample; preserve raw LUID/engine identity.
    # A counter failure never becomes a fabricated zero measurement.
    $paths = @(
        '\GPU Engine(*)\Utilization Percentage',
        '\GPU Adapter Memory(*)\Dedicated Usage',
        '\Processor Information(*)\% Processor Time',
        '\Processor Information(*)\Processor Frequency',
        '\PhysicalDisk(*)\Disk Bytes/sec',
        '\PhysicalDisk(*)\Avg. Disk Queue Length',
        '\Memory\Available MBytes'
    )
    $groups = @(); $failures = @()
    try { $groups = @(Get-Counter -Counter $paths -SampleInterval 1 -MaxSamples 1 -ErrorAction Stop) }
    catch {
        $failures += "Combined counter query: $($_.Exception.Message)"
        foreach ($path in $paths) {
            try { $groups += @(Get-Counter -Counter $path -SampleInterval 1 -MaxSamples 1 -ErrorAction Stop) }
            catch { $failures += "$path`: $($_.Exception.Message)" }
        }
    }
    $pidSet = @{}
    foreach ($proc in @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^(SketchUp|dwm)$' })) {
        $pidSet[[string]$proc.Id] = $true
    }
    $gpu = @(); $cpu = @(); $disk = @(); $adapterMemory = @(); $memoryMb = $null
    foreach ($group in $groups) {
        foreach ($point in $group.CounterSamples) {
            $key = $point.Path.ToLowerInvariant()
            $value = [double]$point.CookedValue
            if ([double]::IsNaN($value) -or [double]::IsInfinity($value)) { continue }
            if ($key -match 'gpu engine\(pid_(\d+)_luid_(0x[0-9a-f]+_0x[0-9a-f]+)_phys_(\d+)_eng_(\d+)_engtype_([^\)]+)\)') {
                # Only busy engines and full SketchUp/DWM attribution; unrelated idle PIDs omitted.
                if ($value -ge 0.1 -or $pidSet.ContainsKey($Matches[1])) {
                    $gpu += [ordered]@{ pid = [int]$Matches[1]; luid = $Matches[2]; physical = [int]$Matches[3]; engine = [int]$Matches[4]; engine_type = $Matches[5]; percent = $value }
                }
            } elseif ($key -match 'gpu adapter memory\(([^\)]+)\)\\dedicated usage') {
                $adapterMemory += [ordered]@{ instance = $Matches[1]; dedicated_bytes = [long]$value }
            } elseif ($key -match 'processor information\(([^\)]+)\)\\(.+)$') {
                $cpu += [ordered]@{ logical_processor = $Matches[1]; counter = $Matches[2]; value = $value }
            } elseif ($key -match 'physicaldisk\(([^\)]+)\)\\(.+)$') {
                $disk += [ordered]@{ disk = $Matches[1]; counter = $Matches[2]; value = $value }
            } elseif ($key -match '\\memory\\available mbytes$') { $memoryMb = $value }
        }
    }
    $nvidiaThermal = $null
    if (Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue) {
        try {
            $nvidiaThermal = (& nvidia-smi.exe --query-gpu=temperature.gpu,power.draw,clocks.gr,utilization.gpu --format=csv,noheader,nounits 2>$null | Out-String).Trim()
        } catch { $failures += "nvidia-smi: $($_.Exception.Message)" }
    }
    return [ordered]@{
        gpu_engines = $gpu; gpu_adapter_memory = $adapterMemory
        logical_cpu = $cpu; disks = $disk; available_memory_mb = $memoryMb
        nvidia_temperature_power_clock_raw = $nvidiaThermal
        intel_temperature_power_clock = $null
        unavailable_counters = $failures
    }
}

if ($Mode -eq 'Finalize') {
    if (-not (Test-Path -LiteralPath (Join-Path $runFolder 'host.json'))) { throw "Unknown run: $runFolder" }
    $trace = $null
    if ($StageReceipt) {
        $trace = Get-Content -LiteralPath $StageReceipt -Raw | ConvertFrom-Json
        if ($trace.schema -ne 'sibambo-performance-trace-v1' -or $trace.enabled -ne $true) {
            throw 'The trace receipt must be an enabled sibambo-performance-trace-v1 receipt.'
        }
    }
    $sampleRows = @()
    $samplePath = Join-Path $runFolder 'samples.jsonl'
    if (Test-Path -LiteralPath $samplePath) {
        $sampleRows = @(Get-Content -LiteralPath $samplePath | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
    }
    $highCore = @(); $gpuPeaks = @{}; $diskPeakBytes = @(); $diskQueue = @(); $sketchUpCpu = @()
    foreach ($sample in $sampleRows) {
        $cores = @($sample.counters.logical_cpu | Where-Object {
            $_.counter -eq '% processor time' -and $_.logical_processor -notmatch '_total'
        })
        if ($cores.Count -gt 0) { $highCore += [double](($cores | Measure-Object -Property value -Maximum).Maximum) }
        foreach ($gpu in @($sample.counters.gpu_engines)) {
            $key = "$($gpu.pid)|$($gpu.luid)|$($gpu.physical)|$($gpu.engine)|$($gpu.engine_type)"
            if (-not $gpuPeaks.ContainsKey($key) -or $gpuPeaks[$key] -lt [double]$gpu.percent) { $gpuPeaks[$key] = [double]$gpu.percent }
        }
        foreach ($disk in @($sample.counters.disks | Where-Object { $_.disk -eq '_total' })) {
            if ($disk.counter -eq 'disk bytes/sec') { $diskPeakBytes += [double]$disk.value }
            if ($disk.counter -eq 'avg. disk queue length') { $diskQueue += [double]$disk.value }
        }
        # Pre-v1 development smoke records wrapped array output in .value.
        $observedProcesses = $sample.processes
        if ($observedProcesses -and $observedProcesses.PSObject.Properties['value']) {
            $observedProcesses = $observedProcesses.value
        }
        foreach ($proc in @($observedProcesses | Where-Object { $_.process -eq 'SketchUp' })) {
            if ($null -ne $proc.cpu_seconds -and $proc.cpu_seconds -is [ValueType]) {
                $sketchUpCpu += [ordered]@{ pid = $proc.pid; at_utc = $sample.end_utc; cumulative_cpu_seconds = [double]$proc.cpu_seconds }
            }
        }
    }
    $gpuSummary = @($gpuPeaks.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 20 | ForEach-Object {
        [ordered]@{ engine_key = $_.Key; observed_peak_percent = $_.Value }
    })
    $cpuDelta = $null
    if ($sketchUpCpu.Count -gt 1 -and $sketchUpCpu[0].pid -eq $sketchUpCpu[-1].pid) {
        $cpuDelta = $sketchUpCpu[-1].cumulative_cpu_seconds - $sketchUpCpu[0].cumulative_cpu_seconds
    }
    $final = [ordered]@{
        schema = 'sibambo-gpu-export-final-v1'; run_id = $RunId
        samples = $sampleRows.Count; trace_receipt = (FileIdentity $StageReceipt)
        metrics = [ordered]@{
            max_logical_cpu_percent = $(if ($highCore.Count) { ($highCore | Measure-Object -Maximum).Maximum } else { $null })
            sketchup_process_cpu_seconds_delta = $cpuDelta
            max_disk_total_bytes_per_sec = $(if ($diskPeakBytes.Count) { ($diskPeakBytes | Measure-Object -Maximum).Maximum } else { $null })
            max_disk_total_queue_length = $(if ($diskQueue.Count) { ($diskQueue | Measure-Object -Maximum).Maximum } else { $null })
            top_gpu_engine_samples = $gpuSummary
            interpretation = 'Counter maxima are samples, not averaged adapter load or a proven export critical path.'
        }
        trace_status = $(if ($trace) { $trace.status } else { 'NOT_RUN' })
        trace_wall_ms = $(if ($trace) { $trace.total_wall_ms } else { $null })
        stages = $(if ($trace) { @($trace.stages | Select-Object name, status, started_ms, finished_ms, duration_ms, cpu_ms) } else { @() })
        artifact = (FileIdentity $ArtifactPath)
        artifact_readback_verified = $false
        provenance_loaded_source_verified = $false
        adapter_luid_mapping_verified = $false
        causal_attribution = 'NOT_ESTABLISHED'
    }
    SaveJson (Join-Path $runFolder 'final.json') $final
    Write-Output "Final receipt: $(Join-Path $runFolder 'final.json')"
    return
}

if (Test-Path -LiteralPath $runFolder) { throw "Run ID already exists; refuse overwrite: $runFolder" }
if ($Mode -eq 'Capture' -and -not $AllowIdleSmoke) {
    if (-not $HostClaimConfirmed) { throw 'Real capture requires -HostClaimConfirmed after checking exclusive SketchUp host ownership.' }
    $active = @(Get-Process -Name SketchUp -ErrorAction SilentlyContinue)
    if ($active.Count -ne 1) { throw 'Capture requires exactly one running SketchUp process; use -AllowIdleSmoke for collector tests only.' }
    if (-not $SourceSkp -or -not $InstallReceipt -or -not $PackageRbz -or
        ($ExportMode -eq 'single' -and $WireEngineId -eq 'unspecified') -or $Profile -eq 'unspecified') {
        throw 'Real capture requires -SourceSkp, -InstallReceipt, -PackageRbz, -Profile, and -WireEngineId for single mode.'
    }
}
[void][System.IO.Directory]::CreateDirectory($runFolder)
try {
    $hostEvidence = CaptureHost
    if ($Mode -eq 'Capture' -and -not $AllowIdleSmoke) {
        if ($hostEvidence.installed_source_markers.Count -ne 2 -or
            @($hostEvidence.installed_source_markers | Where-Object { -not $_.matches_install_receipt }).Count -gt 0 -or
            $hostEvidence.package_rbz.sha256 -ne $hostEvidence.install_receipt.receipt.packageSha256) {
            throw 'Installed markers or candidate RBZ differ from install receipt; refuse non-pinned native capture.'
        }
    }
    SaveJson (Join-Path $runFolder 'host.json') $hostEvidence
    $metadata = [ordered]@{
        schema = 'sibambo-gpu-export-capture-v1'; run_id = $RunId
        kind = $(if ($AllowIdleSmoke) { 'collector_smoke_only' } elseif ($Mode -eq 'Capture') { 'native_host_observation' } else { 'host_snapshot_only' })
        started_utc = (Get-Date).ToUniversalTime().ToString('o')
        wire_engine_id = $WireEngineId; export_mode = $ExportMode; profile = $Profile; cache = $Cache
        adapter_mode_claim = $AdapterMode; adapter_selected_verified = $false
        export_wall_time_verified = $false; source_runtime_loaded_verified = $false
        note = 'External collection window does not prove actual export start/end; attach SketchUp trace and output evidence.'
    }
    SaveJson (Join-Path $runFolder 'capture.json') $metadata
    if ($Mode -eq 'Capture') {
        $samplesFile = Join-Path $runFolder 'samples.jsonl'
        for ($i = 0; $i -lt $Samples; $i++) {
            $before = (Get-Date).ToUniversalTime().ToString('o')
            $counterData = CounterSnapshot
            $row = [ordered]@{
                index = $i; start_utc = $before; end_utc = (Get-Date).ToUniversalTime().ToString('o')
                processes = @(GetProcessSnapshot); counters = $counterData
            }
            ($row | ConvertTo-Json -Depth 20 -Compress) | Add-Content -LiteralPath $samplesFile -Encoding UTF8
        }
    }
    Write-Output "Diagnostic directory: $runFolder"
} catch {
    # Keep partial evidence for investigation; never call an interrupted capture successful.
    throw
}
