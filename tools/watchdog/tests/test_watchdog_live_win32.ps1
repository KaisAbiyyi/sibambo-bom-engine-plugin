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
$summarizerScript = Join-Path $watchdogDir "summarize_watchdog.rb"
$rubyExe = "C:\Ruby25-x64\bin\ruby.exe"

$dummyScript = Join-Path $tmpDir "sib_watchdog_dummy.ps1"
$dummyCode = @'
param(
    [string]$ReadyFile,
    [int]$SleepAtMs = 3000,
    [int]$SleepDurationMs = 6500,
    [int]$CloseAtMs = 15000
)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$form = New-Object System.Windows.Forms.Form
$form.Text = "SibWatchdogDummy"
$form.Width = 420
$form.Height = 200
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.ShowInTaskbar = $true

$label = New-Object System.Windows.Forms.Label
$label.Text = "SibWatchdogDummy test window"
$label.AutoSize = $true
$label.Location = New-Object System.Drawing.Point(20, 40)
$form.Controls.Add($label)

$script:sw = $null
$script:slept = $false
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 50
$timer.Add_Tick({
    if ($null -eq $script:sw) { return }
    $el = $script:sw.ElapsedMilliseconds
    if (-not $script:slept -and $SleepAtMs -gt 0 -and $el -ge $SleepAtMs) {
        $script:slept = $true
        [System.Threading.Thread]::Sleep($SleepDurationMs)
    }
    elseif ($el -ge $CloseAtMs) {
        $timer.Stop()
        $form.Close()
    }
})

$form.Add_Shown({
    $script:sw = [System.Diagnostics.Stopwatch]::StartNew()
    [System.IO.File]::WriteAllText($ReadyFile, "$PID")
    $timer.Start()
})

[System.Windows.Forms.Application]::Run($form)
'@
[System.IO.File]::WriteAllText($dummyScript, ($dummyCode -replace "`r`n", "`n"), (New-Object System.Text.ASCIIEncoding))

function Write-TestBeacon {
    param([string]$Path, [int]$TargetPid, [string]$PhaseGroup, [int]$Seq, [string]$RunDir = "", [string]$SkpSha = "")
    $utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ", [System.Globalization.CultureInfo]::InvariantCulture)
    $obj = @{
        schema = "sibambo-watchdog-beacon-v1"
        pid = $TargetPid
        seq = $Seq
        phase_group = $PhaseGroup
        model = "SibWatchdogDummy"
        run_dir = $RunDir
        skp_sha256 = $SkpSha
        updated_utc = $utc
    }
    $json = $obj | ConvertTo-Json -Compress
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Run-Scenario {
    param(
        [string]$Tag,
        [int]$CloseAtMs,
        [hashtable[]]$Transitions,
        [string[]]$ExtraSummarizerArgs
    )

    $utc = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ")
    $outDir = "D:\projects\sibambo\scratch\watchdog\live-$Tag-$utc"
    $beaconPath = Join-Path $tmpDir "live-beacon-$Tag-$utc.json"
    $readyFile = Join-Path $tmpDir "live-ready-$Tag-$utc.txt"
    $wdStdout = Join-Path $tmpDir "live-wd-out-$Tag-$utc.txt"
    $wdStderr = Join-Path $tmpDir "live-wd-err-$Tag-$utc.txt"
    if (Test-Path -LiteralPath $readyFile) { Remove-Item -LiteralPath $readyFile -Force }

    $dummyProc = Start-Process -FilePath "powershell.exe" `
        -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $dummyScript, "-ReadyFile", $readyFile, "-SleepAtMs", "3000", "-SleepDurationMs", "6500", "-CloseAtMs", "$CloseAtMs") `
        -PassThru

    try {
        $waitSw = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not (Test-Path -LiteralPath $readyFile)) {
            if ($waitSw.Elapsed.TotalSeconds -gt 20) {
                throw "Scenario ${Tag}: dummy did not become ready within 20 s"
            }
            Start-Sleep -Milliseconds 50
        }
        $dummyPid = [int]([System.IO.File]::ReadAllText($readyFile).Trim())
        $t0 = [System.Diagnostics.Stopwatch]::StartNew()

        $seq = 1
        Write-TestBeacon -Path $beaconPath -TargetPid $dummyPid -PhaseGroup $Transitions[0].phase -Seq $seq

        $wdArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $watchdogScript,
            "-TargetPid", "$dummyPid",
            "-BeaconFile", $beaconPath,
            "-ExitWhenTargetExits",
            "-OutDir", $outDir)
        $wdProc = Start-Process -FilePath "powershell.exe" -ArgumentList $wdArgs -PassThru -NoNewWindow `
            -RedirectStandardOutput $wdStdout -RedirectStandardError $wdStderr
        $null = $wdProc.Handle

        for ($i = 1; $i -lt $Transitions.Count; $i++) {
            $targetMs = $Transitions[$i].at_ms
            while ($t0.ElapsedMilliseconds -lt $targetMs) {
                $rem = $targetMs - $t0.ElapsedMilliseconds
                if ($rem -gt 20) { Start-Sleep -Milliseconds ([Math]::Min(100, $rem)) }
                else { Start-Sleep -Milliseconds 10 }
            }
            $seq++
            Write-TestBeacon -Path $beaconPath -TargetPid $dummyPid -PhaseGroup $Transitions[$i].phase -Seq $seq
        }

        if (-not $dummyProc.WaitForExit(30000)) {
            throw "Scenario ${Tag}: dummy did not exit within 30 s"
        }
        if (-not $wdProc.WaitForExit(30000)) {
            try { $wdProc.Kill() } catch { }
            throw "Scenario ${Tag}: watchdog did not exit within 30 s"
        }
        $wdProc.WaitForExit()
        if ($wdProc.ExitCode -ne 0) {
            $errText = if (Test-Path -LiteralPath $wdStderr) { Get-Content -LiteralPath $wdStderr -Raw } else { "" }
            throw "Scenario ${Tag}: watchdog exited with $($wdProc.ExitCode): $errText"
        }

        $eventsPath = Join-Path $outDir "events.ndjson"
        if (-not (Test-Path -LiteralPath $eventsPath)) {
            throw "Scenario ${Tag}: events.ndjson missing"
        }
        $ticks = Get-Content -LiteralPath $eventsPath | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.type -eq "tick" }
        $hungTicks = @($ticks | Where-Object { $_.is_hung -eq $true })
        if ($hungTicks.Count -lt 1) {
            throw "Scenario ${Tag}: expected >= 1 tick with is_hung == true, got $($hungTicks.Count) (outDir=$outDir)"
        }
        $probeFailTicks = @($ticks | Where-Object { $_.probe_ok -eq $false })
        if ($probeFailTicks.Count -lt 1) {
            throw "Scenario ${Tag}: expected >= 1 tick with probe_ok == false, got $($probeFailTicks.Count) (outDir=$outDir)"
        }
        $timeoutTicks = @($probeFailTicks | Where-Object { $_.probe_win32_error -eq 1460 })
        if ($timeoutTicks.Count -lt 1) {
            throw "Scenario ${Tag}: expected >= 1 tick with probe_win32_error == 1460 (ERROR_TIMEOUT), got $($timeoutTicks.Count) (outDir=$outDir)"
        }
        $maxTimeoutLatency = [double](($timeoutTicks | Measure-Object -Property probe_latency_ms -Maximum).Maximum)
        if ($maxTimeoutLatency -lt 450.0) {
            throw "Scenario ${Tag}: expected timeout probe_latency_ms >= 450.0, got $maxTimeoutLatency (outDir=$outDir)"
        }

        $sumArgs = @($summarizerScript, "--session", $outDir) + $ExtraSummarizerArgs
        & $rubyExe @sumArgs
        $sumExit = $LASTEXITCODE
        $sumJson = Get-Content -LiteralPath (Join-Path $outDir "watchdog-summary.json") -Raw | ConvertFrom-Json

        return @{
            out_dir = $outDir
            hung_tick_count = $hungTicks.Count
            probe_fail_count = $probeFailTicks.Count
            timeout_tick_count = $timeoutTicks.Count
            max_timeout_latency_ms = $maxTimeoutLatency
            sum_exit = $sumExit
            summary = $sumJson
        }
    }
    finally {
        if ($null -ne $dummyProc -and -not $dummyProc.HasExited) {
            try { $dummyProc.Kill() } catch { }
        }
        Remove-Item -LiteralPath $readyFile, $beaconPath -ErrorAction SilentlyContinue
    }
}

Write-Output "Running Live Win32 Scenario A..."
$resA = Run-Scenario -Tag "A" -CloseAtMs 15000 -Transitions @(
    @{ at_ms = 0; phase = "open_file" },
    @{ at_ms = 11000; phase = "skp_capture" },
    @{ at_ms = 13000; phase = "idle" }
) -ExtraSummarizerArgs @()

if ($resA.sum_exit -ne 0) {
    throw "Scenario A FAIL: expected summarizer exit 0, got $($resA.sum_exit) (reasons=$($resA.summary.reasons -join ','))"
}
if ($resA.summary.gates.C.max_open_hung_ms -lt 5500) {
    throw "Scenario A FAIL: expected max_open_hung_ms >= 5500, got $($resA.summary.gates.C.max_open_hung_ms)"
}
Write-Output "Scenario A PASS: out_dir=$($resA.out_dir) hung_ticks=$($resA.hung_tick_count) probe_fail_ticks=$($resA.probe_fail_count) timeout_ticks=$($resA.timeout_tick_count) max_timeout_ms=$($resA.max_timeout_latency_ms) max_open_hung_ms=$($resA.summary.gates.C.max_open_hung_ms)"

Write-Output "Running Live Win32 Scenario B..."
$resB = Run-Scenario -Tag "B" -CloseAtMs 14000 -Transitions @(
    @{ at_ms = 0; phase = "open_file" },
    @{ at_ms = 1000; phase = "skp_capture" },
    @{ at_ms = 12000; phase = "idle" }
) -ExtraSummarizerArgs @("--work-hung-limit-ms", "5000")

if ($resB.sum_exit -ne 1) {
    throw "Scenario B FAIL: expected summarizer exit 1, got $($resB.sum_exit)"
}
if ($resB.summary.reasons -notcontains "G-RT4'-A") {
    throw "Scenario B FAIL: expected reason G-RT4'-A, got $($resB.summary.reasons -join ',')"
}
Write-Output "Scenario B PASS: out_dir=$($resB.out_dir) hung_ticks=$($resB.hung_tick_count) probe_fail_ticks=$($resB.probe_fail_count) timeout_ticks=$($resB.timeout_tick_count) max_timeout_ms=$($resB.max_timeout_latency_ms) reasons=$($resB.summary.reasons -join ',')"

# Scenario C: Controlled 30s observer CPU overhead baseline with real 25-manifest batch-exports mounted
Write-Output "Running Live Win32 Scenario C (30s CPU overhead baseline)..."
$utcC = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ")
$outDirC = "D:\projects\sibambo\scratch\watchdog\live-C-$utcC"
$readyC = Join-Path $tmpDir "live-ready-C-$utcC.txt"
$wdOutC = Join-Path $tmpDir "live-wd-out-C-$utcC.txt"
$wdErrC = Join-Path $tmpDir "live-wd-err-C-$utcC.txt"
$batchRootReal = "D:\projects\sibambo\private-evidence\batch-exports"

$dummyC = Start-Process -FilePath "powershell.exe" `
    -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $dummyScript, "-ReadyFile", $readyC, "-SleepAtMs", "0", "-SleepDurationMs", "0", "-CloseAtMs", "30000") `
    -PassThru

try {
    $wSw = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $readyC)) {
        if ($wSw.Elapsed.TotalSeconds -gt 20) { throw "Scenario C: dummy not ready" }
        Start-Sleep -Milliseconds 50
    }
    $dummyPidC = [int]([System.IO.File]::ReadAllText($readyC).Trim())
    $wdProcC = Start-Process -FilePath "powershell.exe" `
        -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $watchdogScript,
            "-TargetPid", "$dummyPidC", "-WatchBatchRoot", $batchRootReal, "-PollIntervalMs", "250",
            "-ExitWhenTargetExits", "-OutDir", $outDirC) `
        -PassThru -NoNewWindow -RedirectStandardOutput $wdOutC -RedirectStandardError $wdErrC
    $null = $wdProcC.Handle

    if (-not $dummyC.WaitForExit(45000)) { throw "Scenario C: dummy did not exit within 45 s" }
    if (-not $wdProcC.WaitForExit(30000)) { try { $wdProcC.Kill() } catch {}; throw "Scenario C: watchdog did not exit" }
    $wdProcC.WaitForExit()
    if ($wdProcC.ExitCode -ne 0) { throw "Scenario C: watchdog exited $($wdProcC.ExitCode)" }

    $evC = Get-Content -LiteralPath (Join-Path $outDirC "events.ndjson") | ForEach-Object { $_ | ConvertFrom-Json }
    $seC = $evC | Where-Object { $_.type -eq "session_end" } | Select-Object -Last 1
    if ($null -eq $seC -or $seC.mono_ms -lt 25000) { throw "Scenario C: invalid session_end mono_ms" }
    $cpuRatio = [double]$seC.watcher_cpu_ms / [double]$seC.mono_ms
    $cpuPct = [Math]::Round($cpuRatio * 100.0, 2)
    if ($cpuRatio -gt 0.030) {
        throw "Scenario C FAIL: watcher CPU ratio $cpuPct% exceeded 3.0% budget (cpu=$($seC.watcher_cpu_ms)ms, wall=$($seC.mono_ms)ms)"
    }
    Write-Output "Scenario C PASS: out_dir=$outDirC wall_ms=$($seC.mono_ms) watcher_cpu_ms=$($seC.watcher_cpu_ms) cpu_pct=${cpuPct}% (<= 3.0%)"
}
finally {
    if ($null -ne $dummyC -and -not $dummyC.HasExited) { try { $dummyC.Kill() } catch { } }
    Remove-Item -LiteralPath $readyC -ErrorAction SilentlyContinue
}

# Scenario D (FI-2): Live 200-rename progress.json race + authoritative skp/manifest.json completion
Write-Output "Running Live Win32 Scenario D (200-rename progress.json race)..."
$utcD = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ")
$outDirD = "D:\projects\sibambo\scratch\watchdog\live-D-$utcD"
$runDirD = Join-Path $tmpDir "live-race-run-$utcD"
$skpDirD = Join-Path $runDirD "skp"
New-Item -ItemType Directory -Force -Path $skpDirD | Out-Null
$progPathD = Join-Path $skpDirD "progress.json"
$manPathD = Join-Path $skpDirD "manifest.json"
[System.IO.File]::WriteAllText($progPathD, '{"phase":"skp_pixels","complete":null}', (New-Object System.Text.UTF8Encoding($false)))

$beaconD = Join-Path $tmpDir "live-beacon-D-$utcD.json"
$readyD = Join-Path $tmpDir "live-ready-D-$utcD.txt"
$wdOutD = Join-Path $tmpDir "live-wd-out-D-$utcD.txt"
$wdErrD = Join-Path $tmpDir "live-wd-err-D-$utcD.txt"
$shaD = "deadbeef" * 8

$dummyD = Start-Process -FilePath "powershell.exe" `
    -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $dummyScript, "-ReadyFile", $readyD, "-SleepAtMs", "0", "-SleepDurationMs", "0", "-CloseAtMs", "10000") `
    -PassThru

try {
    $wSwD = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $readyD)) {
        if ($wSwD.Elapsed.TotalSeconds -gt 20) { throw "Scenario D: dummy not ready" }
        Start-Sleep -Milliseconds 50
    }
    $dummyPidD = [int]([System.IO.File]::ReadAllText($readyD).Trim())
    Write-TestBeacon -Path $beaconD -TargetPid $dummyPidD -PhaseGroup "skp_capture" -Seq 2 -RunDir $runDirD -SkpSha $shaD

    $wdProcD = Start-Process -FilePath "powershell.exe" `
        -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $watchdogScript,
            "-TargetPid", "$dummyPidD", "-BeaconFile", $beaconD, "-PollIntervalMs", "250",
            "-ExitWhenTargetExits", "-OutDir", $outDirD) `
        -PassThru -NoNewWindow -RedirectStandardOutput $wdOutD -RedirectStandardError $wdErrD
    $null = $wdProcD.Handle

    Start-Sleep -Milliseconds 600
    $rubyRaceScript = Join-Path $tmpDir "live_race_writer_$utcD.rb"
    $rubyRaceCode = @"
require 'json'
prog = '$($progPathD -replace '\\','/')'
man = '$($manPathD -replace '\\','/')'
eacces = 0
200.times do |i|
  tmp = "#{prog}.partial"
  File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC | File::BINARY, 0o600) { |f| f.write(JSON.generate(phase: 'skp_pixels', i: i, complete: nil)) }
  begin
    File.rename(tmp, prog)
  rescue Errno::EACCES
    eacces += 1
  end
  sleep 0.025
end
mtmp = "#{man}.partial"
File.open(mtmp, File::WRONLY | File::CREAT | File::TRUNC | File::BINARY, 0o600) do |f|
  f.write(JSON.generate(side: 'skp', complete: true, inputs: { skp_sha256: '$shaD' }))
end
File.rename(mtmp, man)
puts "RACE_EACCES=#{eacces}"
exit(eacces == 0 ? 0 : 1)
"@
    [System.IO.File]::WriteAllText($rubyRaceScript, ($rubyRaceCode -replace "`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
    $raceOut = & $rubyExe $rubyRaceScript
    if ($LASTEXITCODE -ne 0) {
        throw "Scenario D FAIL: Ruby progress.json rename hit Errno::EACCES ($raceOut)"
    }

    if (-not $dummyD.WaitForExit(30000)) { throw "Scenario D: dummy did not exit" }
    if (-not $wdProcD.WaitForExit(30000)) { try { $wdProcD.Kill() } catch {}; throw "Scenario D: watchdog did not exit" }
    $wdProcD.WaitForExit()
    if ($wdProcD.ExitCode -ne 0) { throw "Scenario D: watchdog exited $($wdProcD.ExitCode)" }

    $evD = Get-Content -LiteralPath (Join-Path $outDirD "events.ndjson") | ForEach-Object { $_ | ConvertFrom-Json }
    $termD = @($evD | Where-Object { $_.type -eq "capture_terminal" -and $_.complete -eq $true })
    if ($termD.Count -ne 1) { throw "Scenario D FAIL: expected 1 capture_terminal(complete:true), got $($termD.Count)" }

    & $rubyExe $summarizerScript --session $outDirD
    $sumExitD = $LASTEXITCODE
    if ($sumExitD -ne 0) { throw "Scenario D FAIL: expected summarizer exit 0, got $sumExitD" }
    $sumJsonD = Get-Content -LiteralPath (Join-Path $outDirD "watchdog-summary.json") -Raw | ConvertFrom-Json
    if ($sumJsonD.gates.D.work_exits.Count -ne 0) { throw "Scenario D FAIL: unexpected work_exits" }

    Write-Output "Scenario D PASS: out_dir=$outDirD $raceOut capture_terminal=1 sum_exit=0 work_exits=0"
}
finally {
    if ($null -ne $dummyD -and -not $dummyD.HasExited) { try { $dummyD.Kill() } catch { } }
    Remove-Item -LiteralPath $readyD, $beaconD, $runDirD -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output "LIVE_WIN32_4_OF_4_PASS"
exit 0
