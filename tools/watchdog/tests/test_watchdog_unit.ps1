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
    [System.IO.File]::WriteAllText((Join-Path $batchRunDir "manifest.json"), $batchManifest, (New-Object System.Text.UTF8Encoding($false)))

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
    $cache2 = @{ NowMs = 100.0; LastMtScanMs = -2000.0; MtScanned = $false; MtCandidates = @(); LastBatchScanMs = -2000.0; BatchScanned = $false; BatchResult = $null }
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
    $cacheSingle = @{ NowMs = 100.0; LastMtScanMs = -2000.0; MtScanned = $false; MtCandidates = @(); LastBatchScanMs = -2000.0; BatchScanned = $false; BatchResult = $null }
    $pMt = Resolve-Phase -ProcState $stSingle -BeaconPath "" -ModelTruthRoot $mtRoot -BatchRoot $batchRoot -Cache $cacheSingle -ActiveTargetCount 1
    Assert-True ($pMt.phase_group -eq "skp_capture" -and $pMt.phase_source -eq "model_truth" -and $pMt.model -eq "house2") "U4: Single-PID ModelTruth match"
    $cacheBatchOpen = @{ NowMs = 100.0; LastMtScanMs = -2000.0; MtScanned = $false; MtCandidates = @(); LastBatchScanMs = -2000.0; BatchScanned = $false; BatchResult = $null }
    $pBatchOpen = Resolve-Phase -ProcState $stSingle -BeaconPath "" -ModelTruthRoot "" -BatchRoot $batchRoot -Cache $cacheBatchOpen -ActiveTargetCount 1
    Assert-True ($pBatchOpen.phase_group -eq "batch_open_skp" -and $pBatchOpen.phase_source -eq "batch") "U4: Single-PID batch_open_skp without temp dir"
    New-Item -ItemType Directory -Force -Path (Join-Path $attemptDir "temp") | Out-Null
    $cacheBatchExp = @{ NowMs = 2000.0; LastMtScanMs = -2000.0; MtScanned = $false; MtCandidates = @(); LastBatchScanMs = -2000.0; BatchScanned = $false; BatchResult = $null }
    $pBatchExp = Resolve-Phase -ProcState $stSingle -BeaconPath "" -ModelTruthRoot "" -BatchRoot $batchRoot -Cache $cacheBatchExp -ActiveTargetCount 1
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

    # U6: Valid resource metric read on current process returns positive numbers
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

    Write-Output "WATCHDOG_UNIT_6_OF_6_PASS"
    exit 0
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
