[CmdletBinding()]
param(
    [string]$OutDir = "",
    [string]$ProcessName = "SketchUp",
    [int]$TargetPid = 0,
    [int]$PollIntervalMs = 250,
    [int]$ProbeTimeoutMs = 500,
    [int]$HeartbeatSeconds = 5,
    [string]$WatchBatchRoot = "D:\projects\sibambo\private-evidence\batch-exports",
    [string]$WatchModelTruthRoot = "",
    [string]$BeaconFile = "",
    [switch]$ExitWhenTargetExits,
    [int]$MaxDurationSeconds = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# 1. Validate ranges (invalid -> exit 2)
if ($PollIntervalMs -lt 100 -or $PollIntervalMs -gt 1000) {
    [Console]::Error.WriteLine("ERROR: PollIntervalMs must be 100..1000 (got $PollIntervalMs)")
    exit 2
}
if ($ProbeTimeoutMs -lt 200 -or $ProbeTimeoutMs -gt 2000) {
    [Console]::Error.WriteLine("ERROR: ProbeTimeoutMs must be 200..2000 (got $ProbeTimeoutMs)")
    exit 2
}
if ($HeartbeatSeconds -lt 1) {
    [Console]::Error.WriteLine("ERROR: HeartbeatSeconds must be >= 1 (got $HeartbeatSeconds)")
    exit 2
}
if ($TargetPid -lt 0) {
    [Console]::Error.WriteLine("ERROR: TargetPid must be >= 0 (got $TargetPid)")
    exit 2
}
if ($MaxDurationSeconds -lt 0) {
    [Console]::Error.WriteLine("ERROR: MaxDurationSeconds must be >= 0 (got $MaxDurationSeconds)")
    exit 2
}
if ([string]::IsNullOrWhiteSpace($ProcessName) -and $TargetPid -eq 0) {
    [Console]::Error.WriteLine("ERROR: ProcessName required when TargetPid is 0")
    exit 2
}

# 2. Set TEMP/TMP on D: before Add-Type
$tmpDir = "D:\projects\sibambo\scratch\watchdog\tmp"
if (-not (Test-Path -LiteralPath $tmpDir)) {
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
}
$env:TEMP = $tmpDir
$env:TMP = $tmpDir

# 3. Compile Native Win32 helper (failure -> exit 2)
$nativeSource = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace Sibambo.SkpWatchdog
{
    public class WindowInfo
    {
        public IntPtr Hwnd;
        public int Pid;
        public IntPtr Owner;
        public string ClassName;
        public string Title;
        public long Area;
    }

    public class ProcEntry
    {
        public int Pid;
        public int ParentPid;
        public string ExeName;
    }

    public class ProbeResult
    {
        public bool IsHung;
        public bool ProbeOk;
        public double LatencyMs;
        public int Win32Error;
    }

    public class ProcStats
    {
        public double WorkingSetMiB;
        public double PrivateMiB;
        public long CreationFileTimeUtc;
        public long CpuUserMs;
        public long CpuKernelMs;
        public int GdiObjects;
        public int UserObjects;
        public bool MemoryOk;
        public bool TimesOk;
        public bool GdiOk;
        public bool UserOk;
    }

    public static class Native
    {
        public const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
        public const uint SYNCHRONIZE = 0x00100000;
        private const uint GW_OWNER = 4;
        private const uint WM_NULL = 0x0000;
        private const uint SMTO_BLOCK = 0x0001;
        private const uint SMTO_ABORTIFHUNG = 0x0002;
        private const uint TH32CS_SNAPPROCESS = 0x00000002;
        private const uint GR_GDIOBJECTS = 0;
        private const uint GR_USEROBJECTS = 1;
        private const int MAX_PATH = 260;

        private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [StructLayout(LayoutKind.Sequential)]
        private struct RECT
        {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct PROCESSENTRY32W
        {
            public uint dwSize;
            public uint cntUsage;
            public uint th32ProcessID;
            public IntPtr th32DefaultHeapID;
            public uint th32ModuleID;
            public uint cntThreads;
            public uint th32ParentProcessID;
            public int pcPriClassBase;
            public uint dwFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = MAX_PATH)]
            public string szExeFile;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct PROCESS_MEMORY_COUNTERS_EX
        {
            public uint cb;
            public uint PageFaultCount;
            public UIntPtr PeakWorkingSetSize;
            public UIntPtr WorkingSetSize;
            public UIntPtr QuotaPeakPagedPoolUsage;
            public UIntPtr QuotaPagedPoolUsage;
            public UIntPtr QuotaPeakNonPagedPoolUsage;
            public UIntPtr QuotaNonPagedPoolUsage;
            public UIntPtr PagefileUsage;
            public UIntPtr PeakPagefileUsage;
            public UIntPtr PrivateUsage;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct FILETIME
        {
            public uint dwLowDateTime;
            public uint dwHighDateTime;
            public long ToLong()
            {
                return ((long)dwHighDateTime << 32) | (uint)dwLowDateTime;
            }
        }

        [DllImport("user32.dll")]
        private static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern bool IsWindowVisible(IntPtr hWnd);

        [DllImport("user32.dll")]
        private static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetWindowTextW(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetClassNameW(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

        [DllImport("user32.dll")]
        private static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

        [DllImport("user32.dll")]
        private static extern bool IsHungAppWindow(IntPtr hWnd);

        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern IntPtr SendMessageTimeoutW(
            IntPtr hWnd, uint Msg, UIntPtr wParam, IntPtr lParam,
            uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint GetGuiResources(IntPtr hProcess, uint uiFlags);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, uint dwProcessId);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetProcessTimes(
            IntPtr hProcess, out FILETIME lpCreationTime, out FILETIME lpExitTime,
            out FILETIME lpKernelTime, out FILETIME lpUserTime);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetExitCodeProcess(IntPtr hProcess, out uint lpExitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr hObject);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr CreateToolhelp32Snapshot(uint dwFlags, uint th32ProcessID);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        private static extern bool Process32FirstW(IntPtr hSnapshot, ref PROCESSENTRY32W lppe);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        private static extern bool Process32NextW(IntPtr hSnapshot, ref PROCESSENTRY32W lppe);

        [DllImport("psapi.dll", SetLastError = true)]
        private static extern bool GetProcessMemoryInfo(IntPtr Process, out PROCESS_MEMORY_COUNTERS_EX ppsmemCounters, uint cb);

        public static IntPtr OpenTargetProcess(int pid)
        {
            return OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, false, (uint)pid);
        }

        public static void CloseTargetHandle(IntPtr handle)
        {
            if (handle != IntPtr.Zero)
            {
                CloseHandle(handle);
            }
        }

        public static bool TryGetExitCode(IntPtr handle, out int exitCode)
        {
            exitCode = 0;
            if (handle == IntPtr.Zero) return false;
            uint code;
            if (!GetExitCodeProcess(handle, out code)) return false;
            exitCode = unchecked((int)code);
            return true;
        }

        public static bool TryGetCreationFileTime(IntPtr handle, out long creationFt)
        {
            creationFt = 0;
            if (handle == IntPtr.Zero) return false;
            FILETIME c, e, k, u;
            if (!GetProcessTimes(handle, out c, out e, out k, out u)) return false;
            creationFt = c.ToLong();
            return true;
        }

        public static List<WindowInfo> SnapshotWindows()
        {
            var list = new List<WindowInfo>();
            var sbTitle = new StringBuilder(512);
            var sbClass = new StringBuilder(256);
            EnumWindows(delegate(IntPtr hWnd, IntPtr lParam)
            {
                if (!IsWindowVisible(hWnd)) return true;
                uint pid = 0;
                GetWindowThreadProcessId(hWnd, out pid);
                IntPtr owner = GetWindow(hWnd, GW_OWNER);
                sbClass.Clear();
                GetClassNameW(hWnd, sbClass, sbClass.Capacity);
                sbTitle.Clear();
                GetWindowTextW(hWnd, sbTitle, sbTitle.Capacity);
                RECT rc;
                long area = 0;
                if (GetWindowRect(hWnd, out rc))
                {
                    long w = Math.Max(0, (long)rc.Right - rc.Left);
                    long h = Math.Max(0, (long)rc.Bottom - rc.Top);
                    area = w * h;
                }
                list.Add(new WindowInfo
                {
                    Hwnd = hWnd,
                    Pid = unchecked((int)pid),
                    Owner = owner,
                    ClassName = sbClass.ToString(),
                    Title = sbTitle.ToString(),
                    Area = area
                });
                return true;
            }, IntPtr.Zero);
            return list;
        }

        public static List<ProcEntry> SnapshotProcesses()
        {
            var list = new List<ProcEntry>();
            IntPtr snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
            if (snap == IntPtr.Zero || snap == new IntPtr(-1)) return list;
            try
            {
                var pe = new PROCESSENTRY32W();
                pe.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32W));
                if (Process32FirstW(snap, ref pe))
                {
                    do
                    {
                        list.Add(new ProcEntry
                        {
                            Pid = unchecked((int)pe.th32ProcessID),
                            ParentPid = unchecked((int)pe.th32ParentProcessID),
                            ExeName = pe.szExeFile ?? string.Empty
                        });
                    }
                    while (Process32NextW(snap, ref pe));
                }
            }
            finally
            {
                CloseHandle(snap);
            }
            return list;
        }

        public static ProbeResult ProbeWindow(IntPtr hWnd, int timeoutMs)
        {
            bool hung = IsHungAppWindow(hWnd);
            UIntPtr result;
            var sw = Stopwatch.StartNew();
            IntPtr ret = SendMessageTimeoutW(
                hWnd, WM_NULL, UIntPtr.Zero, IntPtr.Zero,
                SMTO_BLOCK | SMTO_ABORTIFHUNG, (uint)timeoutMs, out result);
            sw.Stop();
            int err = ret == IntPtr.Zero ? Marshal.GetLastWin32Error() : 0;
            return new ProbeResult
            {
                IsHung = hung,
                ProbeOk = (ret != IntPtr.Zero),
                LatencyMs = Math.Round(sw.Elapsed.TotalMilliseconds, 1),
                Win32Error = err
            };
        }

        public static ProcStats GetProcStats(IntPtr handle)
        {
            var stats = new ProcStats();
            if (handle == IntPtr.Zero) return stats;

            var mem = new PROCESS_MEMORY_COUNTERS_EX();
            mem.cb = (uint)Marshal.SizeOf(typeof(PROCESS_MEMORY_COUNTERS_EX));
            if (GetProcessMemoryInfo(handle, out mem, mem.cb))
            {
                stats.WorkingSetMiB = Math.Round(mem.WorkingSetSize.ToUInt64() / 1048576.0, 1);
                stats.PrivateMiB = Math.Round(mem.PrivateUsage.ToUInt64() / 1048576.0, 1);
                stats.MemoryOk = true;
            }

            FILETIME c, e, k, u;
            if (GetProcessTimes(handle, out c, out e, out k, out u))
            {
                stats.CreationFileTimeUtc = c.ToLong();
                stats.CpuKernelMs = k.ToLong() / 10000L;
                stats.CpuUserMs = u.ToLong() / 10000L;
                stats.TimesOk = true;
            }

            uint gdi = GetGuiResources(handle, GR_GDIOBJECTS);
            int gdiErr = Marshal.GetLastWin32Error();
            if (gdi > 0 || (gdiErr == 0 && stats.TimesOk))
            {
                stats.GdiObjects = unchecked((int)gdi);
                stats.GdiOk = true;
            }

            uint usr = GetGuiResources(handle, GR_USEROBJECTS);
            int usrErr = Marshal.GetLastWin32Error();
            if (usr > 0 || (usrErr == 0 && stats.TimesOk))
            {
                stats.UserObjects = unchecked((int)usr);
                stats.UserOk = true;
            }
            return stats;
        }
    }
}
'@

try {
    if (-not ("Sibambo.SkpWatchdog.Native" -as [type])) {
        Add-Type -TypeDefinition $nativeSource -Language CSharp
    }
}
catch {
    [Console]::Error.WriteLine("ERROR: Add-Type failed: $($_.Exception.Message)")
    exit 2
}

# Deterministic JSON serializer (preserves empty/1-element arrays, exact booleans/nulls/numbers)
function ConvertTo-JsonScalar {
    param([object]$Val)
    if ($null -eq $Val) { return "null" }
    if ($Val -is [bool]) { if ($Val) { return "true" } else { return "false" } }
    if ($Val -is [int] -or $Val -is [long]) { return $Val.ToString([System.Globalization.CultureInfo]::InvariantCulture) }
    if ($Val -is [double] -or $Val -is [float] -or $Val -is [decimal]) {
        return ([double]$Val).ToString("0.0###", [System.Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Val -is [string]) {
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append('"')
        foreach ($ch in $Val.ToCharArray()) {
            $code = [int]$ch
            switch ($ch) {
                '"'  { [void]$sb.Append('\"') }
                '\'  { [void]$sb.Append('\\') }
                "`b" { [void]$sb.Append('\b') }
                "`f" { [void]$sb.Append('\f') }
                "`n" { [void]$sb.Append('\n') }
                "`r" { [void]$sb.Append('\r') }
                "`t" { [void]$sb.Append('\t') }
                default {
                    if ($code -lt 32 -or $code -gt 126) {
                        [void]$sb.AppendFormat("\u{0:x4}", $code)
                    }
                    else {
                        [void]$sb.Append($ch)
                    }
                }
            }
        }
        [void]$sb.Append('"')
        return $sb.ToString()
    }
    if ($Val -is [System.Collections.IDictionary]) {
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($k in $Val.Keys) {
            $kj = ConvertTo-JsonScalar ([string]$k)
            $vj = ConvertTo-JsonScalar $Val[$k]
            $parts.Add("${kj}:${vj}")
        }
        return "{" + ($parts -join ",") + "}"
    }
    if ($Val -is [System.Collections.IEnumerable]) {
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($item in $Val) {
            $parts.Add((ConvertTo-JsonScalar $item))
        }
        return "[" + ($parts -join ",") + "]"
    }
    return (ConvertTo-JsonScalar ([string]$Val))
}

function Get-UtcIso {
    return [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ", [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-MonoMs {
    param([System.Diagnostics.Stopwatch]$Sw)
    return [Math]::Round($Sw.Elapsed.TotalMilliseconds, 1)
}

function Get-JsonProp {
    param([object]$Obj, [string]$Name)
    if ($null -eq $Obj) { return $null }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function Test-GhostWindowMatch {
    param([string]$LastHealthyTitle, [object]$GhostTitles)
    if ([string]::IsNullOrEmpty($LastHealthyTitle) -or $null -eq $GhostTitles) { return $false }
    $prefixLen = [Math]::Min(40, $LastHealthyTitle.Length)
    $prefix = $LastHealthyTitle.Substring(0, $prefixLen)
    foreach ($gt in $GhostTitles) {
        if ($null -ne $gt -and ([string]$gt).StartsWith($prefix, [System.StringComparison]::Ordinal)) {
            return $true
        }
    }
    return $false
}

function Get-ProcessMetricsSnapshot {
    param([IntPtr]$Handle, [int]$TargetPid)
    $pStats = [Sibambo.SkpWatchdog.Native]::GetProcStats($Handle)
    $handleCount = $null
    if ($Handle -ne [IntPtr]::Zero -and $TargetPid -gt 0) {
        try {
            $handleCount = [System.Diagnostics.Process]::GetProcessById($TargetPid).HandleCount
        }
        catch {
            $handleCount = $null
        }
    }
    return @{
        working_set_mib = if ($pStats.MemoryOk) { $pStats.WorkingSetMiB } else { $null }
        private_mib = if ($pStats.MemoryOk) { $pStats.PrivateMiB } else { $null }
        cpu_user_ms = if ($pStats.TimesOk) { $pStats.CpuUserMs } else { $null }
        cpu_kernel_ms = if ($pStats.TimesOk) { $pStats.CpuKernelMs } else { $null }
        handles = $handleCount
        gdi = if ($pStats.GdiOk) { $pStats.GdiObjects } else { $null }
        user = if ($pStats.UserOk) { $pStats.UserObjects } else { $null }
    }
}

function Get-ModelTruthCandidates {
    param([string]$Root)
    $list = @()
    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root)) { return ,$list }
    try {
        $files = Get-ChildItem -LiteralPath $Root -Filter "progress.json" -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { (Split-Path $_.DirectoryName -Leaf) -eq "skp" } |
            Sort-Object LastWriteTimeUtc -Descending
        foreach ($f in $files) {
            try {
                $raw = [System.IO.File]::ReadAllText($f.FullName)
                $obj = $raw | ConvertFrom-Json
                if ($null -eq (Get-JsonProp $obj "complete")) {
                    $skpDir = $f.DirectoryName
                    $runDir = Split-Path $skpDir -Parent
                    $modelDir = Split-Path $runDir -Parent
                    $modelName = Split-Path $modelDir -Leaf
                    $list += @{
                        LastWriteTimeUtc = $f.LastWriteTimeUtc
                        Model = $modelName
                    }
                }
            }
            catch { }
        }
    }
    catch { }
    return ,$list
}

function Resolve-ModelTruthFromCandidates {
    param([object]$Candidates, [datetime]$CreationUtc)
    if ($null -eq $Candidates) { return $null }
    foreach ($cand in $Candidates) {
        if ($cand.LastWriteTimeUtc -ge $CreationUtc) {
            return @{
                phase_group = "skp_capture"
                phase_source = "model_truth"
                model = $cand.Model
            }
        }
    }
    return $null
}

function Resolve-BatchRoot {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root)) { return $null }
    try {
        $manifests = Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue |
            ForEach-Object {
                $mp = Join-Path $_.FullName "manifest.json"
                if (Test-Path -LiteralPath $mp) { Get-Item -LiteralPath $mp }
            } | Sort-Object LastWriteTimeUtc -Descending

        foreach ($mf in $manifests) {
            try {
                $man = [System.IO.File]::ReadAllText($mf.FullName) | ConvertFrom-Json
                $status = [string](Get-JsonProp $man "status")
                if ($status -notin @("running", "cancel_requested", "pause_requested")) { continue }
                $cur = Get-JsonProp $man "current"
                if ($null -eq $cur) { continue }
                $curModel = [string](Get-JsonProp $cur "model")
                $curEngine = [string](Get-JsonProp $cur "engine")
                $curProfile = [string](Get-JsonProp $cur "profile")
                $curStage = [string](Get-JsonProp $cur "stage")
                if ([string]::IsNullOrEmpty($curModel) -or [string]::IsNullOrEmpty($curEngine) -or [string]::IsNullOrEmpty($curProfile)) { continue }

                $modelsRaw = Get-JsonProp $man "models"
                if ($null -eq $modelsRaw) { continue }
                $models = @($modelsRaw)
                $row = $models | Where-Object { (Get-JsonProp $_ "relative") -eq $curModel } | Select-Object -First 1
                if ($null -eq $row) { continue }
                $exports = Get-JsonProp $row "exports"
                $expEngine = Get-JsonProp $exports $curEngine
                $expProfile = Get-JsonProp $expEngine $curProfile
                $attemptsRaw = Get-JsonProp $expProfile "attempts"
                if ($null -eq $attemptsRaw) { continue }
                $attempts = @($attemptsRaw)
                if ($attempts.Count -eq 0) { continue }

                $lastAttempt = $attempts[$attempts.Count - 1]
                $artifactPath = [string](Get-JsonProp $lastAttempt "path")
                if ([string]::IsNullOrEmpty($artifactPath)) { continue }
                $attemptDir = [System.IO.Path]::GetDirectoryName($artifactPath)
                if ([string]::IsNullOrEmpty($attemptDir)) { continue }

                $tempDirPath = Join-Path $attemptDir "temp"
                if ($curStage -eq "OPEN_SKP" -and -not (Test-Path -LiteralPath $tempDirPath)) {
                    $pg = "batch_open_skp"
                }
                else {
                    $pg = "batch_export"
                }
                return @{
                    phase_group = $pg
                    phase_source = "batch"
                    model = $curModel
                }
            }
            catch { }
        }
    }
    catch { }
    return $null
}

function Resolve-Phase {
    param(
        [hashtable]$ProcState,
        [string]$BeaconPath,
        [string]$ModelTruthRoot,
        [string]$BatchRoot,
        [hashtable]$Cache,
        [int]$ActiveTargetCount = 1
    )

    # 1. Beacon (read every tick; unambiguous per-PID ownership)
    if (-not [string]::IsNullOrWhiteSpace($BeaconPath) -and (Test-Path -LiteralPath $BeaconPath)) {
        try {
            $b = [System.IO.File]::ReadAllText($BeaconPath) | ConvertFrom-Json
            $schema = [string](Get-JsonProp $b "schema")
            $bPid = Get-JsonProp $b "pid"
            $bUpd = [string](Get-JsonProp $b "updated_utc")
            if ($schema -eq "sibambo-watchdog-beacon-v1" -and $null -ne $bPid -and ([int]$bPid) -eq $ProcState.Pid -and -not [string]::IsNullOrEmpty($bUpd)) {
                $upd = [DateTimeOffset]::Parse($bUpd, [System.Globalization.CultureInfo]::InvariantCulture).UtcDateTime
                if ($upd -ge $ProcState.CreationUtc) {
                    $pg = [string](Get-JsonProp $b "phase_group")
                    $bModel = [string](Get-JsonProp $b "model")
                    $model = if ([string]::IsNullOrEmpty($bModel)) { $null } else { $bModel }
                    $bRunDir = [string](Get-JsonProp $b "run_dir")
                    if ($pg -eq "skp_capture" -and -not [string]::IsNullOrWhiteSpace($bRunDir)) {
                        $progPath = Join-Path $bRunDir "skp\progress.json"
                        if (Test-Path -LiteralPath $progPath) {
                            try {
                                $prog = [System.IO.File]::ReadAllText($progPath) | ConvertFrom-Json
                                $progComplete = Get-JsonProp $prog "complete"
                                if ($progComplete -is [bool]) {
                                    $pg = "idle"
                                }
                            }
                            catch { }
                        }
                    }
                    $ProcState.HasBeenAttributed = $true
                    return @{ phase_group = $pg; phase_source = "beacon"; model = $model }
                }
            }
        }
        catch { }
    }

    $nowMs = $Cache.NowMs
    # 2. ModelTruth root (scanned every 1000 ms; candidates cached across PIDs, filtered per PID)
    $mtMatch = $null
    if (-not [string]::IsNullOrWhiteSpace($ModelTruthRoot)) {
        if (($nowMs - $Cache.LastMtScanMs) -ge 1000.0 -or -not $Cache.MtScanned) {
            $Cache.LastMtScanMs = $nowMs
            $Cache.MtScanned = $true
            $Cache.MtCandidates = Get-ModelTruthCandidates -Root $ModelTruthRoot
        }
        $mtMatch = Resolve-ModelTruthFromCandidates -Candidates $Cache.MtCandidates -CreationUtc $ProcState.CreationUtc
    }

    # 3. Batch root (scanned every 1000 ms)
    $batchMatch = $null
    if (-not [string]::IsNullOrWhiteSpace($BatchRoot)) {
        if (($nowMs - $Cache.LastBatchScanMs) -ge 1000.0 -or -not $Cache.BatchScanned) {
            $Cache.LastBatchScanMs = $nowMs
            $Cache.BatchScanned = $true
            $Cache.BatchResult = Resolve-BatchRoot -Root $BatchRoot
        }
        $batchMatch = $Cache.BatchResult
    }

    # Multi-PID: ModelTruth and Batch roots do not carry PID ownership -> fail closed to UNKNOWN
    if ($ActiveTargetCount -gt 1) {
        if ($null -ne $mtMatch -or $null -ne $batchMatch) {
            return @{ phase_group = "unattributed"; phase_source = "none"; model = $null }
        }
    }
    else {
        if ($null -ne $mtMatch) {
            $ProcState.HasBeenAttributed = $true
            return $mtMatch
        }
        if ($null -ne $batchMatch) {
            $ProcState.HasBeenAttributed = $true
            return $batchMatch
        }
    }

    # 4. Startup
    if (-not $ProcState.HasBeenAttributed) {
        return @{ phase_group = "startup"; phase_source = "startup"; model = $null }
    }

    # 5. Unattributed
    return @{ phase_group = "unattributed"; phase_source = "none"; model = $null }
}

function Get-DescendantNames {
    param([int]$RootPid, [hashtable]$ChildrenByParent)
    $names = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::Ordinal)
    if ($ChildrenByParent.ContainsKey($RootPid)) {
        foreach ($c1 in $ChildrenByParent[$RootPid]) {
            [void]$names.Add($c1.ExeName)
            if ($ChildrenByParent.ContainsKey($c1.Pid)) {
                foreach ($c2 in $ChildrenByParent[$c1.Pid]) {
                    [void]$names.Add($c2.ExeName)
                }
            }
        }
    }
    $arr = New-Object string[] $names.Count
    $names.CopyTo($arr)
    [System.Array]::Sort($arr, [System.StringComparer]::Ordinal)
    return ,$arr
}

if ($MyInvocation.InvocationName -ne '.') {
# 4. Prepare OutDir (existing events.ndjson -> exit 2)
if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $utcTag = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ")
    $rngBytes = New-Object byte[] 3
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($rngBytes)
    $hex6 = ([System.BitConverter]::ToString($rngBytes) -replace '-', '').ToLowerInvariant()
    $OutDir = "D:\projects\sibambo\outputs\watchdog\$utcTag-$hex6"
}
$OutDir = [System.IO.Path]::GetFullPath($OutDir)

if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
}
$eventsPath = Join-Path $OutDir "events.ndjson"
if (Test-Path -LiteralPath $eventsPath) {
    [Console]::Error.WriteLine("ERROR: events.ndjson already exists at $eventsPath")
    exit 2
}

Write-Output $OutDir

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$writer = $null
$tracked = @{}
$seenAnyTarget = $false
$ticksTotal = 0
$ticksWritten = 0
$endReason = "interrupted"
$sessionSw = [System.Diagnostics.Stopwatch]::StartNew()
$selfProc = [System.Diagnostics.Process]::GetCurrentProcess()
$watcherCpuStartMs = $selfProc.TotalProcessorTime.TotalMilliseconds

function Write-EventLine {
    param([hashtable]$Obj)
    $line = ConvertTo-JsonScalar $Obj
    $writer.WriteLine($line)
    $writer.Flush()
}

try {
    $writer = New-Object System.IO.StreamWriter($eventsPath, $false, $utf8NoBom)

    Write-EventLine @{
        type = "session_start"
        utc = (Get-UtcIso)
        mono_ms = (Get-MonoMs $sessionSw)
        schema = "sibambo-skp-watchdog-v1"
        ps_version = $PSVersionTable.PSVersion.ToString()
        poll_interval_ms = $PollIntervalMs
        probe_timeout_ms = $ProbeTimeoutMs
        heartbeat_seconds = $HeartbeatSeconds
        target = @{
            process_name = $ProcessName
            pid = $TargetPid
        }
        watch = @{
            beacon_file = $BeaconFile
            model_truth_root = $WatchModelTruthRoot
            batch_root = $WatchBatchRoot
        }
        out_dir = $OutDir
    }

    $scanCache = @{
        NowMs = 0.0
        LastMtScanMs = -2000.0
        MtScanned = $false
        MtCandidates = @()
        LastBatchScanMs = -2000.0
        BatchScanned = $false
        BatchResult = $null
    }

    $nextTickStartMs = $sessionSw.Elapsed.TotalMilliseconds

    while ($true) {
        $tickStartMs = $sessionSw.Elapsed.TotalMilliseconds
        if ($MaxDurationSeconds -gt 0 -and ($tickStartMs / 1000.0) -ge $MaxDurationSeconds) {
            $endReason = "max_duration"
            break
        }

        $scanCache.NowMs = $tickStartMs

        # Snapshot processes & windows once per tick
        $procSnap = [Sibambo.SkpWatchdog.Native]::SnapshotProcesses()
        $winSnap = [Sibambo.SkpWatchdog.Native]::SnapshotWindows()

        $procByPid = @{}
        $childrenByParent = @{}
        foreach ($p in $procSnap) {
            $procByPid[$p.Pid] = $p
            if (-not $childrenByParent.ContainsKey($p.ParentPid)) {
                $childrenByParent[$p.ParentPid] = New-Object System.Collections.Generic.List[object]
            }
            $childrenByParent[$p.ParentPid].Add($p)
        }

        $targetExeLower = if ($ProcessName.ToLowerInvariant().EndsWith(".exe")) {
            $ProcessName.ToLowerInvariant()
        }
        else {
            ($ProcessName + ".exe").ToLowerInvariant()
        }

        $liveTargetPids = New-Object System.Collections.Generic.List[int]
        if ($TargetPid -gt 0) {
            if ($procByPid.ContainsKey($TargetPid)) {
                $liveTargetPids.Add($TargetPid)
            }
        }
        else {
            foreach ($p in $procSnap) {
                if ($p.ExeName.ToLowerInvariant() -eq $targetExeLower) {
                    $liveTargetPids.Add($p.Pid)
                }
            }
        }

        # Check exited targets
        $trackedKeys = @($tracked.Keys)
        foreach ($tPid in $trackedKeys) {
            if (-not $liveTargetPids.Contains($tPid)) {
                $st = $tracked[$tPid]
                $code = 0
                $readable = [Sibambo.SkpWatchdog.Native]::TryGetExitCode($st.Handle, [ref]$code)
                [Sibambo.SkpWatchdog.Native]::CloseTargetHandle($st.Handle)
                $tracked.Remove($tPid)
                Write-EventLine @{
                    type = "process_exited"
                    utc = (Get-UtcIso)
                    mono_ms = (Get-MonoMs $sessionSw)
                    pid = $tPid
                    exit_code = if ($readable) { $code } else { $null }
                    exit_code_readable = $readable
                }
            }
        }

        # Register newly seen targets
        foreach ($tPid in $liveTargetPids) {
            if (-not $tracked.ContainsKey($tPid)) {
                $seenAnyTarget = $true
                $hProc = [Sibambo.SkpWatchdog.Native]::OpenTargetProcess($tPid)
                $cFt = 0L
                $cUtc = [DateTime]::UtcNow
                if ([Sibambo.SkpWatchdog.Native]::TryGetCreationFileTime($hProc, [ref]$cFt) -and $cFt -gt 0) {
                    $cUtc = [DateTime]::FromFileTimeUtc($cFt)
                }
                else {
                    try {
                        $cUtc = [System.Diagnostics.Process]::GetProcessById($tPid).StartTime.ToUniversalTime()
                    }
                    catch { }
                }
                $imgPath = ""
                try {
                    $imgPath = [System.Diagnostics.Process]::GetProcessById($tPid).MainModule.FileName
                }
                catch {
                    if ($procByPid.ContainsKey($tPid)) { $imgPath = $procByPid[$tPid].ExeName }
                }

                $tracked[$tPid] = @{
                    Pid = $tPid
                    Handle = $hProc
                    CreationUtc = $cUtc
                    HasBeenAttributed = $false
                    LastHealthyTitle = ""
                    HealthyAfterStallLeft = 0
                    LastWrittenMonoMs = -999999.0
                    PrevPhaseGroup = $null
                    PrevTitle = $null
                    PrevModalKey = $null
                    PrevChildrenKey = $null
                }

                Write-EventLine @{
                    type = "process_started"
                    utc = (Get-UtcIso)
                    mono_ms = (Get-MonoMs $sessionSw)
                    pid = $tPid
                    creation_utc = $cUtc.ToString("yyyy-MM-ddTHH:mm:ss.fffZ", [System.Globalization.CultureInfo]::InvariantCulture)
                    image_path = $imgPath
                }
            }
        }

        if ($ExitWhenTargetExits -and $seenAnyTarget -and $tracked.Count -eq 0) {
            $endReason = "target_exited"
            break
        }

        # Group windows by PID & collect global Ghost windows
        $winsByPid = @{}
        $ghostTitles = New-Object System.Collections.Generic.List[string]
        foreach ($w in $winSnap) {
            if ($w.ClassName -eq "Ghost") {
                $ghostTitles.Add($w.Title)
            }
            if (-not $winsByPid.ContainsKey($w.Pid)) {
                $winsByPid[$w.Pid] = New-Object System.Collections.Generic.List[object]
            }
            $winsByPid[$w.Pid].Add($w)
        }

        # Sample each live tracked PID
        foreach ($tPid in @($tracked.Keys)) {
            $st = $tracked[$tPid]
            $ticksTotal++

            $pidWins = if ($winsByPid.ContainsKey($tPid)) { $winsByPid[$tPid] } else { @() }

            # D42.1 Main window: visible, no owner, class != #32770, largest area, ties -> lowest HWND
            $mainWin = $null
            $modalList = New-Object System.Collections.Generic.List[hashtable]
            foreach ($w in $pidWins) {
                if ($w.ClassName -eq "#32770") {
                    $modalList.Add(@{ class = "#32770"; title = $w.Title })
                    continue
                }
                if ($w.Owner -eq [IntPtr]::Zero) {
                    if ($null -eq $mainWin) {
                        $mainWin = $w
                    }
                    elseif ($w.Area -gt $mainWin.Area) {
                        $mainWin = $w
                    }
                    elseif ($w.Area -eq $mainWin.Area -and $w.Hwnd.ToInt64() -lt $mainWin.Hwnd.ToInt64()) {
                        $mainWin = $w
                    }
                }
            }

            $mainHwndHex = $null
            $probeOk = $true
            $probeLatencyMs = 0.0
            $probeErr = $null
            $isHung = $false
            $title = ""
            $titleNr = $false
            $ghost = $false

            if ($null -ne $mainWin) {
                $mainHwndHex = "0x" + $mainWin.Hwnd.ToInt64().ToString("x")
                $pr = [Sibambo.SkpWatchdog.Native]::ProbeWindow($mainWin.Hwnd, $ProbeTimeoutMs)
                $isHung = $pr.IsHung
                $probeOk = $pr.ProbeOk
                $probeLatencyMs = $pr.LatencyMs
                $probeErr = if ($pr.ProbeOk) { $null } else { $pr.Win32Error }
                $title = $mainWin.Title
                $titleNr = ($title -match '\(Not Responding\)')
            }

            # D42.4 Ghost check across ALL top-level visible windows (independent of main window presence)
            $ghost = Test-GhostWindowMatch -LastHealthyTitle $st.LastHealthyTitle -GhostTitles $ghostTitles

            $stall = (-not $probeOk) -or $isHung -or $ghost -or $titleNr
            if (-not $stall -and -not [string]::IsNullOrEmpty($title)) {
                $st.LastHealthyTitle = $title
            }

            # D42.6 Process data
            $metrics = Get-ProcessMetricsSnapshot -Handle $st.Handle -TargetPid $tPid
            $childrenArr = Get-DescendantNames -RootPid $tPid -ChildrenByParent $childrenByParent

            # D44 Phase attribution
            $phaseInfo = Resolve-Phase -ProcState $st -BeaconPath $BeaconFile -ModelTruthRoot $WatchModelTruthRoot -BatchRoot $WatchBatchRoot -Cache $scanCache -ActiveTargetCount $tracked.Count
            $phaseGroup = $phaseInfo.phase_group
            $phaseSource = $phaseInfo.phase_source
            $modelVal = $phaseInfo.model

            # D43 Change events
            $eventWrittenThisTick = $false
            if ($null -ne $st.PrevPhaseGroup -and $st.PrevPhaseGroup -ne $phaseGroup) {
                Write-EventLine @{
                    type = "phase_changed"
                    utc = (Get-UtcIso)
                    mono_ms = (Get-MonoMs $sessionSw)
                    pid = $tPid
                    from = $st.PrevPhaseGroup
                    to = $phaseGroup
                    source = $phaseSource
                    model = $modelVal
                }
                $eventWrittenThisTick = $true
            }
            $st.PrevPhaseGroup = $phaseGroup

            if ($null -ne $st.PrevTitle -and $st.PrevTitle -ne $title) {
                Write-EventLine @{
                    type = "title_changed"
                    utc = (Get-UtcIso)
                    mono_ms = (Get-MonoMs $sessionSw)
                    pid = $tPid
                    title = $title
                }
                $eventWrittenThisTick = $true
            }
            $st.PrevTitle = $title

            $modalArr = $modalList.ToArray()
            $modalKey = ConvertTo-JsonScalar $modalArr
            if ($null -ne $st.PrevModalKey -and $st.PrevModalKey -ne $modalKey) {
                Write-EventLine @{
                    type = "modal_changed"
                    utc = (Get-UtcIso)
                    mono_ms = (Get-MonoMs $sessionSw)
                    pid = $tPid
                    modal = $modalArr
                }
                $eventWrittenThisTick = $true
            }
            $st.PrevModalKey = $modalKey

            $childrenKey = $childrenArr -join "`n"
            if ($null -ne $st.PrevChildrenKey -and $st.PrevChildrenKey -ne $childrenKey) {
                Write-EventLine @{
                    type = "children_changed"
                    utc = (Get-UtcIso)
                    mono_ms = (Get-MonoMs $sessionSw)
                    pid = $tPid
                    children = $childrenArr
                }
                $eventWrittenThisTick = $true
            }
            $st.PrevChildrenKey = $childrenKey

            # D43 Tick write policy
            $nowMonoMs = Get-MonoMs $sessionSw
            $shouldWriteTick = $false
            if ($stall) {
                $st.HealthyAfterStallLeft = 2
                $shouldWriteTick = $true
            }
            elseif ($st.HealthyAfterStallLeft -gt 0) {
                $st.HealthyAfterStallLeft--
                $shouldWriteTick = $true
            }
            if ($eventWrittenThisTick) {
                $shouldWriteTick = $true
            }
            if (($nowMonoMs - $st.LastWrittenMonoMs) -ge ($HeartbeatSeconds * 1000.0)) {
                $shouldWriteTick = $true
            }

            if ($shouldWriteTick) {
                $st.LastWrittenMonoMs = $nowMonoMs
                $ticksWritten++
                Write-EventLine @{
                    type = "tick"
                    utc = (Get-UtcIso)
                    mono_ms = $nowMonoMs
                    pid = $tPid
                    main_hwnd = $mainHwndHex
                    probe_ok = $probeOk
                    probe_latency_ms = $probeLatencyMs
                    probe_win32_error = $probeErr
                    is_hung = $isHung
                    ghost = $ghost
                    title = $title
                    title_nr = $titleNr
                    modal = $modalArr
                    stall = $stall
                    phase_group = $phaseGroup
                    phase_source = $phaseSource
                    model = $modelVal
                    working_set_mib = $metrics.working_set_mib
                    private_mib = $metrics.private_mib
                    cpu_user_ms = $metrics.cpu_user_ms
                    cpu_kernel_ms = $metrics.cpu_kernel_ms
                    handles = $metrics.handles
                    gdi = $metrics.gdi
                    user = $metrics.user
                    children = $childrenArr
                }
            }
        }

        $tickEndMs = $sessionSw.Elapsed.TotalMilliseconds
        $nextTickStartMs = [Math]::Max($tickStartMs + $PollIntervalMs, $tickEndMs)
        $sleepMs = [int][Math]::Ceiling($nextTickStartMs - $tickEndMs)
        if ($sleepMs -gt 0) {
            [System.Threading.Thread]::Sleep($sleepMs)
        }
    }
}
catch {
    $endReason = "error"
    [Console]::Error.WriteLine("ERROR: $($_.Exception.Message)")
    throw
}
finally {
    foreach ($tPid in @($tracked.Keys)) {
        try { [Sibambo.SkpWatchdog.Native]::CloseTargetHandle($tracked[$tPid].Handle) } catch { }
    }
    if ($null -ne $writer) {
        try {
            $watcherCpuMs = [int][Math]::Round($selfProc.TotalProcessorTime.TotalMilliseconds - $watcherCpuStartMs)
            Write-EventLine @{
                type = "session_end"
                utc = (Get-UtcIso)
                mono_ms = (Get-MonoMs $sessionSw)
                reason = $endReason
                ticks_total = $ticksTotal
                ticks_written = $ticksWritten
                watcher_cpu_ms = $watcherCpuMs
            }
        }
        catch { }
        try { $writer.Dispose() } catch { }
    }
}

exit 0
}
