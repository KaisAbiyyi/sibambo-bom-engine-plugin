Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$tmpDir = "D:\projects\sibambo\scratch\watchdog\tmp"
if (-not (Test-Path -LiteralPath $tmpDir)) {
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
}
$env:TEMP = $tmpDir
$env:TMP = $tmpDir

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$watchdogDir = Split-Path -Parent $scriptDir
$watchdogScript = Join-Path $watchdogDir "skp_watchdog.ps1"

. $watchdogScript

function Assert-True {
    param([bool]$Cond, [string]$Msg)
    if (-not $Cond) {
        throw "ASSERT_FAIL: $Msg"
    }
}

function New-ProcState {
    param([int]$PidVal, [datetime]$CreationUtc)
    return @{
        Pid = $PidVal
        Handle = [IntPtr]::Zero
        CreationUtc = $CreationUtc
        HasBeenAttributed = $false
        LastHealthyTitle = ""
        HealthyAfterStallLeft = 0
        LastWrittenMonoMs = -999999.0
        PrevPhaseGroup = $null
        PrevTitle = $null
        PrevModalKey = $null
        PrevChildrenKey = $null
        LastLifecycleSeq = 0
        LifecycleStatuses = @{}
        CaptureTerminalEmitted = $false
        LastProgCheckMs = -10000.0
        LastProgMtimeTicks = -1L
        LastProgChangeMonoMs = 0.0
        StallWarningEmitted = $false
    }
}

function New-ScanCache {
    param([double]$NowMs = 100.0)
    return @{
        NowMs = $NowMs
        LastMtScanMs = -2000.0
        MtScanned = $false
        MtCandidates = @()
        LastBatchScanMs = -2000.0
        BatchScanned = $false
        BatchResult = @{ State = "none"; Match = $null }
        FileCache = @{}
    }
}

$testRoot = Join-Path $tmpDir ("unit-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Force -Path $testRoot | Out-Null

try {
    # U1: Ghost detection independent of main window presence and isolated per PID title history
    $ghostTitles = @("house2.skp - SketchUp 2026 (Not Responding)")
    $hitMissingMain = Test-GhostWindowMatch -LastHealthyTitle "house2.skp - SketchUp 2026" -GhostTitles $ghostTitles
    $missOtherPid = Test-GhostWindowMatch -LastHealthyTitle "other_model.skp - SketchUp 2026" -GhostTitles $ghostTitles
    $missEmptyHistory = Test-GhostWindowMatch -LastHealthyTitle "" -GhostTitles $ghostTitles
    Assert-True $hitMissingMain "U1: expected Ghost match even when main window is absent"
    Assert-True (-not $missOtherPid) "U1: expected no Ghost match for PID with different title history"
    Assert-True (-not $missEmptyHistory) "U1: expected no Ghost match when LastHealthyTitle is empty"
    Write-Output "U1 PASS: Ghost detection independent of main window & isolated per PID"

    # Setup ModelTruth & Batch fixtures in D:\projects\sibambo\scratch\watchdog\tmp\unit-...
    $mtRoot = Join-Path $testRoot "mt_root"
    $mtSkpDir = Join-Path $mtRoot "house2\20261124T000000Z\skp"
    New-Item -ItemType Directory -Force -Path $mtSkpDir | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $mtSkpDir "progress.json"), '{"phase":"scan","complete":null}', (New-Object System.Text.UTF8Encoding($false)))

    $batchRoot = Join-Path $testRoot "batch_root"
    $batchRunDir = Join-Path $batchRoot "run1"
    $attemptDir = Join-Path $testRoot "attempts\house2\e4-exact-1"
    New-Item -ItemType Directory -Force -Path $batchRunDir, $attemptDir | Out-Null
    $artifactPath = Join-Path $attemptDir "artifact.bomc"
    $batchManifest = @{
        status = "running"
        current = @{
            model = "house2.skp"
            engine = "e4"
            profile = "exact"
            stage = "OPEN_SKP"
        }
        models = @(
            @{
                relative = "house2.skp"
                exports = @{
                    e4 = @{
                        exact = @{
                            attempts = @(
                                @{ path = $artifactPath }
                            )
                        }
                    }
                }
            }
        )
    } | ConvertTo-Json -Depth 8
    $batchManPath = Join-Path $batchRunDir "manifest.json"
    [System.IO.File]::WriteAllText($batchManPath, $batchManifest, (New-Object System.Text.UTF8Encoding($false)))

    $beaconFile = Join-Path $testRoot "beacon.json"
    $tCreation = [DateTime]::UtcNow.AddSeconds(-30)
    $beaconJson = @{
        schema = "sibambo-watchdog-beacon-v1"
        pid = 101
        seq = 1
        phase_group = "skp_capture"
        model = "house2"
        updated_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
    } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($beaconFile, $beaconJson, (New-Object System.Text.UTF8Encoding($false)))

    # U2: Multi-PID (2 instances): PID 101 has beacon, PID 202 does not -> PID 202 fails closed to unattributed (UNKNOWN)
    $st101 = New-ProcState -PidVal 101 -CreationUtc $tCreation
    $st202 = New-ProcState -PidVal 202 -CreationUtc $tCreation
    $cache2 = New-ScanCache
    $p101 = Resolve-Phase -ProcState $st101 -BeaconPath $beaconFile -ModelTruthRoot $mtRoot -BatchRoot $batchRoot -Cache $cache2 -ActiveTargetCount 2
    $p202 = Resolve-Phase -ProcState $st202 -BeaconPath $beaconFile -ModelTruthRoot $mtRoot -BatchRoot $batchRoot -Cache $cache2 -ActiveTargetCount 2
    Assert-True ($p101.phase_group -eq "skp_capture" -and $p101.phase_source -eq "beacon") "U2: PID 101 should use beacon"
    Assert-True ($p202.phase_group -eq "unattributed" -and $p202.phase_source -eq "none" -and $null -eq $p202.model) "U2: PID 202 must fail closed to unattributed when multi-PID"
    Write-Output "U2 PASS: Multi-PID beacon isolation & fail-closed UNKNOWN"

    # U3: Multi-PID without any beacon -> both fail closed to unattributed
    $st301 = New-ProcState -PidVal 301 -CreationUtc $tCreation
    $st302 = New-ProcState -PidVal 302 -CreationUtc $tCreation
    $p301 = Resolve-Phase -ProcState $st301 -BeaconPath "" -ModelTruthRoot "" -BatchRoot $batchRoot -Cache $cache2 -ActiveTargetCount 2
    $p302 = Resolve-Phase -ProcState $st302 -BeaconPath "" -ModelTruthRoot "" -BatchRoot $batchRoot -Cache $cache2 -ActiveTargetCount 2
    Assert-True ($p301.phase_group -eq "unattributed" -and $p301.phase_source -eq "none") "U3: PID 301 must fail closed"
    Assert-True ($p302.phase_group -eq "unattributed" -and $p302.phase_source -eq "none") "U3: PID 302 must fail closed"
    Write-Output "U3 PASS: Multi-PID without beacon fails closed"

    # U4: Single-PID preserves ModelTruth & Batch attribution (batch_open_skp vs batch_export)
    $stSingle = New-ProcState -PidVal 401 -CreationUtc $tCreation
    $pMt = Resolve-Phase -ProcState $stSingle -BeaconPath "" -ModelTruthRoot $mtRoot -BatchRoot $batchRoot -Cache (New-ScanCache) -ActiveTargetCount 1
    Assert-True ($pMt.phase_group -eq "skp_capture" -and $pMt.phase_source -eq "model_truth" -and $pMt.model -eq "house2") "U4: Single-PID ModelTruth match"
    $pBatchOpen = Resolve-Phase -ProcState $stSingle -BeaconPath "" -ModelTruthRoot "" -BatchRoot $batchRoot -Cache (New-ScanCache) -ActiveTargetCount 1
    Assert-True ($pBatchOpen.phase_group -eq "batch_open_skp" -and $pBatchOpen.phase_source -eq "batch") "U4: Single-PID batch_open_skp without temp dir"
    New-Item -ItemType Directory -Force -Path (Join-Path $attemptDir "temp") | Out-Null
    $pBatchExp = Resolve-Phase -ProcState $stSingle -BeaconPath "" -ModelTruthRoot "" -BatchRoot $batchRoot -Cache (New-ScanCache 2000.0) -ActiveTargetCount 1
    Assert-True ($pBatchExp.phase_group -eq "batch_export" -and $pBatchExp.phase_source -eq "batch") "U4: Single-PID batch_export when temp dir exists"
    Write-Output "U4 PASS: Single-PID ModelTruth and Batch attribution preserved"

    # U5: Resource metric read failure produces null (not 0)
    $badMetrics = Get-ProcessMetricsSnapshot -Handle ([IntPtr]::Zero) -TargetPid 99999999
    foreach ($k in @("working_set_mib", "private_mib", "cpu_user_ms", "cpu_kernel_ms", "handles", "gdi", "user")) {
        Assert-True ($null -eq $badMetrics[$k]) "U5: expected $k to be null on failed read"
    }
    $badJson = ConvertTo-JsonScalar $badMetrics
    Assert-True ($badJson -notmatch ':0(\.0)?[,}]') "U5: failed metrics must serialize as null, not 0 ($badJson)"
    Write-Output "U5 PASS: Failed resource metrics serialize as null"

    # U6: Valid resource metric read on current process returns positive numbers (via GetProcessHandleCount)
    $hSelf = [Sibambo.SkpWatchdog.Native]::OpenTargetProcess($PID)
    try {
        Assert-True ($hSelf -ne [IntPtr]::Zero) "U6: OpenTargetProcess($PID) returned zero handle"
        $goodMetrics = Get-ProcessMetricsSnapshot -Handle $hSelf -TargetPid $PID
        Assert-True ($null -ne $goodMetrics.working_set_mib -and $goodMetrics.working_set_mib -gt 0) "U6: working_set_mib must be > 0"
        Assert-True ($null -ne $goodMetrics.handles -and $goodMetrics.handles -gt 0) "U6: handles must be > 0"
        Assert-True ($null -ne $goodMetrics.cpu_user_ms -and $goodMetrics.cpu_user_ms -ge 0) "U6: cpu_user_ms must be non-null"
        Assert-True ($null -ne $goodMetrics.cpu_kernel_ms -and $goodMetrics.cpu_kernel_ms -ge 0) "U6: cpu_kernel_ms must be non-null"
    }
    finally {
        [Sibambo.SkpWatchdog.Native]::CloseTargetHandle($hSelf)
    }
    Write-Output "U6 PASS: Valid resource metrics read cleanly"

    # U7 (FI-3 stale batch): stale manifest (mtime < CreationUtc) is ignored -> startup
    $staleBatchRoot = Join-Path $testRoot "stale_batch_root"
    $staleRunDir = Join-Path $staleBatchRoot "old_run"
    New-Item -ItemType Directory -Force -Path $staleRunDir | Out-Null
    $staleManPath = Join-Path $staleRunDir "manifest.json"
    [System.IO.File]::WriteAllText($staleManPath, $batchManifest, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::SetLastWriteTimeUtc($staleManPath, [DateTime]::UtcNow.AddHours(-2))
    $stStale = New-ProcState -PidVal 501 -CreationUtc ([DateTime]::UtcNow.AddSeconds(-5))
    $pStale = Resolve-Phase -ProcState $stStale -BeaconPath "" -ModelTruthRoot "" -BatchRoot $staleBatchRoot -Cache (New-ScanCache) -ActiveTargetCount 1
    Assert-True ($pStale.phase_group -eq "startup" -and $pStale.phase_source -eq "startup") "U7: stale batch manifest must be ignored (-> startup)"
    Write-Output "U7 PASS: Stale batch manifest ignored"

    # U8 (FI-3 concurrent batch): two fresh running manifests -> fail-closed unattributed
    $concBatchRoot = Join-Path $testRoot "conc_batch_root"
    $cRun1 = Join-Path $concBatchRoot "runA"
    $cRun2 = Join-Path $concBatchRoot "runB"
    New-Item -ItemType Directory -Force -Path $cRun1, $cRun2 | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $cRun1 "manifest.json"), $batchManifest, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText((Join-Path $cRun2 "manifest.json"), $batchManifest, (New-Object System.Text.UTF8Encoding($false)))
    $stConc = New-ProcState -PidVal 502 -CreationUtc $tCreation
    $pConc = Resolve-Phase -ProcState $stConc -BeaconPath "" -ModelTruthRoot "" -BatchRoot $concBatchRoot -Cache (New-ScanCache) -ActiveTargetCount 1
    Assert-True ($pConc.phase_group -eq "unattributed" -and $pConc.phase_source -eq "none") "U8: concurrent fresh batch manifests must fail closed to unattributed"
    Write-Output "U8 PASS: Concurrent fresh batch manifests fail closed"

    # U9: Get-EffectiveBatchRoot disables default WatchBatchRoot when BeaconFile is set and WatchBatchRoot unbound
    $effDisabled = Get-EffectiveBatchRoot -BeaconPath $beaconFile -BatchRoot $batchRoot -BatchRootBound $false
    $effBound = Get-EffectiveBatchRoot -BeaconPath $beaconFile -BatchRoot $batchRoot -BatchRootBound $true
    $effNoBeacon = Get-EffectiveBatchRoot -BeaconPath "" -BatchRoot $batchRoot -BatchRootBound $false
    Assert-True ($effDisabled -eq "") "U9: WatchBatchRoot should be disabled when BeaconFile is set and WatchBatchRoot is unbound"
    Assert-True ($effBound -eq $batchRoot) "U9: explicit WatchBatchRoot should remain enabled"
    Assert-True ($effNoBeacon -eq $batchRoot) "U9: WatchBatchRoot without BeaconFile should remain enabled"
    Write-Output "U9 PASS: BeaconFile disables unbound WatchBatchRoot"

    # U10: Authoritative skp/manifest.json (complete: true) transitions skp_capture -> idle + emits capture_terminal even if progress.json stays complete:null
    $capRun = Join-Path $testRoot "cap_run"
    $capSkp = Join-Path $capRun "skp"
    New-Item -ItemType Directory -Force -Path $capSkp | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $capSkp "progress.json"), '{"phase":"finish","complete":null}', (New-Object System.Text.UTF8Encoding($false)))
    $capBeacon = Join-Path $testRoot "cap_beacon.json"
    $capSha = "abc123"
    $capBeaconObj = @{
        schema = "sibambo-watchdog-beacon-v1"
        pid = 601
        seq = 2
        phase_group = "skp_capture"
        model = "house2"
        run_dir = $capRun
        skp_sha256 = $capSha
        updated_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        lifecycle = @(
            @{ seq = 1; phase_group = "open_file"; status = "completed"; started_utc = [DateTime]::UtcNow.AddSeconds(-1).ToString("yyyy-MM-ddTHH:mm:ss.fffZ"); ended_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ"); duration_ms = 64.0 }
            @{ seq = 2; phase_group = "skp_capture"; status = "started"; started_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ"); ended_utc = $null; duration_ms = $null }
        )
    } | ConvertTo-Json -Depth 6 -Compress
    [System.IO.File]::WriteAllText($capBeacon, $capBeaconObj, (New-Object System.Text.UTF8Encoding($false)))
    $capManObj = @{ side = "skp"; complete = $true; inputs = @{ skp_sha256 = $capSha } } | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText((Join-Path $capSkp "manifest.json"), $capManObj, (New-Object System.Text.UTF8Encoding($false)))
    $stCap = New-ProcState -PidVal 601 -CreationUtc $tCreation
    $pCap = Resolve-Phase -ProcState $stCap -BeaconPath $capBeacon -ModelTruthRoot "" -BatchRoot "" -Cache (New-ScanCache) -ActiveTargetCount 1
    Assert-True ($pCap.phase_group -eq "idle" -and $pCap.phase_source -eq "beacon") "U10: skp/manifest.json complete:true must transition skp_capture -> idle"
    $termEvs = @($pCap.events | Where-Object { $_.type -eq "capture_terminal" })
    Assert-True ($termEvs.Count -eq 1 -and $termEvs[0].complete -eq $true) "U10: expected 1 capture_terminal(complete:true) event"

    # U11: Sub-poll lifecycle entries emit beacon_lifecycle events without fabricating tick lines
    $lcEvs = @($pCap.events | Where-Object { $_.type -eq "beacon_lifecycle" })
    Assert-True ($lcEvs.Count -eq 2) "U11: expected 2 beacon_lifecycle events, got $($lcEvs.Count)"
    Assert-True ($lcEvs[0].phase_group -eq "open_file" -and $lcEvs[0].duration_ms -eq 64.0) "U11: expected sub-poll open_file duration_ms=64.0"
    Assert-True ((@($pCap.events | Where-Object { $_.type -eq "tick" })).Count -eq 0) "U11: must not fabricate tick lines"
    Write-Output "U10 & U11 PASS: skp/manifest.json terminal transition & beacon_lifecycle emitted cleanly"

    # U12 (FI-4): Stale progress.json mtime triggers capture_progress_stalled without opening progress.json
    $stRun = Join-Path $testRoot "stale_prog_run"
    $stSkp = Join-Path $stRun "skp"
    New-Item -ItemType Directory -Force -Path $stSkp | Out-Null
    $stProgPath = Join-Path $stSkp "progress.json"
    [System.IO.File]::WriteAllText($stProgPath, '{"phase":"skp_pixels","complete":null}', (New-Object System.Text.UTF8Encoding($false)))
    $stProgFi = [System.IO.FileInfo]::new($stProgPath)
    $stBeacon = Join-Path $testRoot "stale_prog_beacon.json"
    $stBeaconObj = @{
        schema = "sibambo-watchdog-beacon-v1"
        pid = 602
        seq = 2
        phase_group = "skp_capture"
        model = "rumah10x14"
        run_dir = $stRun
        updated_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
    } | ConvertTo-Json -Depth 4 -Compress
    [System.IO.File]::WriteAllText($stBeacon, $stBeaconObj, (New-Object System.Text.UTF8Encoding($false)))
    $stProgState = New-ProcState -PidVal 602 -CreationUtc $tCreation
    $stProgState.LastProgMtimeTicks = $stProgFi.LastWriteTimeUtc.Ticks
    $stProgState.LastProgChangeMonoMs = 1000.0
    $stProgState.LastProgCheckMs = 0.0
    $pStaleProg = Resolve-Phase -ProcState $stProgState -BeaconPath $stBeacon -ModelTruthRoot "" -BatchRoot "" -Cache (New-ScanCache 15000.0) -ActiveTargetCount 1 -ProgressStaleSeconds 10
    $stallWarnEvs = @($pStaleProg.events | Where-Object { $_.type -eq "capture_progress_stalled" })
    Assert-True ($stallWarnEvs.Count -eq 1 -and $stallWarnEvs[0].stale_seconds -ge 10.0) "U12: expected capture_progress_stalled event"
    Write-Output "U12 PASS: capture_progress_stalled emitted via stat-only mtime check"

    Write-Output "WATCHDOG_UNIT_12_OF_12_PASS"
    exit 0
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
