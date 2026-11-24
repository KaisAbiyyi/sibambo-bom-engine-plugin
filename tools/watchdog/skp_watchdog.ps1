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
    [int]$MaxDurationSeconds = 0,
    [int]$ProgressStaleSeconds = 120
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
if ($ProgressStaleSeconds -lt 0) {
    [Console]::Error.WriteLine("ERROR: ProgressStaleSeconds must be >= 0 (got $ProgressStaleSeconds)")
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
    public class PidWindowSample
    {
        public int Pid;
        public IntPtr MainHwnd;
        public string MainTitle;
        public string[] ModalTitles;
        public bool GhostMatched;
    }

    public class PidFastSample
    {
        public int Pid;
        public bool Exited;
        public int ExitCode;
        public bool ExitCodeReadable;
        public IntPtr MainHwnd;
        public string MainTitle;
        public string[] ModalTitles;
        public bool GhostMatched;
        public bool IsHung;
        public bool ProbeOk;
        public double ProbeLatencyMs;
        public int ProbeWin32Error;
        public bool TitleNr;
        public bool Stall;
        public ProcStats Stats;
    }

    public class TargetTreeSnapshot
    {
        public int[] LiveTargetPids;
        public Dictionary<int, string[]> ChildrenByPid;
    }

    public class TrackedTargetSpec
    {
        public int Pid;
        public IntPtr Handle;
        public long CreationFileTimeUtc;
        public string LastHealthyPrefix;
        public string PrevTitle;
        public string PrevModalKey;
        public string PrevChildrenKey;
        public int HealthyAfterStallLeft;
        public double LastWrittenMonoMs;
        public bool ForcePhaseCheckOnToolhelp;
        public string LastBeaconStamp;
    }

    public class PollWakeResult
    {
        public bool HitMaxDuration;
        public bool DidToolhelp;
        public double LastToolhelpMs;
        public int TicksSampled;
        public int[] LiveTargetPids;
        public Dictionary<int, string[]> ChildrenByPid;
        public PidFastSample[] FastSamples;
        public double WakeTickStartMs;
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
        public int HandleCount;
        public int GdiObjects;
        public int UserObjects;
        public bool MemoryOk;
        public bool TimesOk;
        public bool HandleCountOk;
        public bool GdiOk;
        public bool UserOk;
    }

    public static class Native
    {
        public const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
        public const uint SYNCHRONIZE = 0x00100000;
        public const int STILL_ACTIVE = 259;
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

        private struct ProcRow
        {
            public int Pid;
            public int ParentPid;
            public string ExeName;
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
        private static extern bool GetProcessHandleCount(IntPtr hProcess, out uint pdwHandleCount);

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

        public static PidWindowSample[] SamplePidWindows(int[] targetPids, string[] lastHealthyPrefixes)
        {
            int n = targetPids == null ? 0 : targetPids.Length;
            var samples = new PidWindowSample[n];
            var pidIndex = new Dictionary<int, int>(n);
            var bestArea = new long[n];
            var modals = new List<string>[n];

            for (int i = 0; i < n; i++)
            {
                samples[i] = new PidWindowSample
                {
                    Pid = targetPids[i],
                    MainHwnd = IntPtr.Zero,
                    MainTitle = string.Empty,
                    ModalTitles = new string[0],
                    GhostMatched = false
                };
                bestArea[i] = -1;
                modals[i] = new List<string>();
                pidIndex[targetPids[i]] = i;
            }

            var ghostTitles = new List<string>();
            var sbTitle = new StringBuilder(512);
            var sbClass = new StringBuilder(256);

            EnumWindows(delegate(IntPtr hWnd, IntPtr lParam)
            {
                if (!IsWindowVisible(hWnd)) return true;

                sbClass.Clear();
                GetClassNameW(hWnd, sbClass, sbClass.Capacity);
                string cls = sbClass.ToString();

                if (cls == "Ghost")
                {
                    sbTitle.Clear();
                    GetWindowTextW(hWnd, sbTitle, sbTitle.Capacity);
                    ghostTitles.Add(sbTitle.ToString());
                }

                if (n == 0) return true;

                uint rawPid = 0;
                GetWindowThreadProcessId(hWnd, out rawPid);
                int pid = unchecked((int)rawPid);
                int idx;
                if (!pidIndex.TryGetValue(pid, out idx)) return true;

                sbTitle.Clear();
                GetWindowTextW(hWnd, sbTitle, sbTitle.Capacity);
                string title = sbTitle.ToString();

                if (cls == "#32770")
                {
                    modals[idx].Add(title);
                    return true;
                }

                if (GetWindow(hWnd, GW_OWNER) == IntPtr.Zero)
                {
                    RECT rc;
                    long area = 0;
                    if (GetWindowRect(hWnd, out rc))
                    {
                        long w = Math.Max(0, (long)rc.Right - rc.Left);
                        long h = Math.Max(0, (long)rc.Bottom - rc.Top);
                        area = w * h;
                    }
                    IntPtr curBest = samples[idx].MainHwnd;
                    if (curBest == IntPtr.Zero ||
                        area > bestArea[idx] ||
                        (area == bestArea[idx] && hWnd.ToInt64() < curBest.ToInt64()))
                    {
                        bestArea[idx] = area;
                        samples[idx].MainHwnd = hWnd;
                        samples[idx].MainTitle = title;
                    }
                }
                return true;
            }, IntPtr.Zero);

            for (int i = 0; i < n; i++)
            {
                samples[i].ModalTitles = modals[i].ToArray();
                string prefix = (lastHealthyPrefixes != null && i < lastHealthyPrefixes.Length) ? lastHealthyPrefixes[i] : null;
                if (!string.IsNullOrEmpty(prefix))
                {
                    for (int g = 0; g < ghostTitles.Count; g++)
                    {
                        if (ghostTitles[g].StartsWith(prefix, StringComparison.Ordinal))
                        {
                            samples[i].GhostMatched = true;
                            break;
                        }
                    }
                }
            }
            return samples;
        }

        public static TargetTreeSnapshot SnapshotTargetTree(string targetExeLower, int targetPid)
        {
            var rows = new List<ProcRow>(256);
            IntPtr snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
            if (snap != IntPtr.Zero && snap != new IntPtr(-1))
            {
                try
                {
                    var pe = new PROCESSENTRY32W();
                    pe.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32W));
                    if (Process32FirstW(snap, ref pe))
                    {
                        do
                        {
                            rows.Add(new ProcRow
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
            }

            var liveTargets = new List<int>();
            var byParent = new Dictionary<int, List<ProcRow>>(rows.Count);
            for (int i = 0; i < rows.Count; i++)
            {
                var r = rows[i];
                List<ProcRow> children;
                if (!byParent.TryGetValue(r.ParentPid, out children))
                {
                    children = new List<ProcRow>();
                    byParent[r.ParentPid] = children;
                }
                children.Add(r);

                if (targetPid > 0)
                {
                    if (r.Pid == targetPid) liveTargets.Add(r.Pid);
                }
                else if (r.ExeName.Equals(targetExeLower, StringComparison.OrdinalIgnoreCase))
                {
                    liveTargets.Add(r.Pid);
                }
            }

            var childMap = new Dictionary<int, string[]>(liveTargets.Count);
            for (int i = 0; i < liveTargets.Count; i++)
            {
                int root = liveTargets[i];
                var names = new HashSet<string>(StringComparer.Ordinal);
                List<ProcRow> d1;
                if (byParent.TryGetValue(root, out d1))
                {
                    for (int j = 0; j < d1.Count; j++)
                    {
                        names.Add(d1[j].ExeName);
                        List<ProcRow> d2;
                        if (byParent.TryGetValue(d1[j].Pid, out d2))
                        {
                            for (int k = 0; k < d2.Count; k++)
                            {
                                names.Add(d2[k].ExeName);
                            }
                        }
                    }
                }
                var arr = new string[names.Count];
                names.CopyTo(arr);
                Array.Sort(arr, StringComparer.Ordinal);
                childMap[root] = arr;
            }

            return new TargetTreeSnapshot
            {
                LiveTargetPids = liveTargets.ToArray(),
                ChildrenByPid = childMap
            };
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

        public static string JsonEscape(string s)
        {
            if (string.IsNullOrEmpty(s)) return "\"\"";
            var sb = new StringBuilder(s.Length + 8);
            sb.Append('"');
            for (int i = 0; i < s.Length; i++)
            {
                char ch = s[i];
                switch (ch)
                {
                    case '"': sb.Append("\\\""); break;
                    case '\\': sb.Append("\\\\"); break;
                    case '\b': sb.Append("\\b"); break;
                    case '\f': sb.Append("\\f"); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': sb.Append("\\r"); break;
                    case '\t': sb.Append("\\t"); break;
                    default:
                        int code = (int)ch;
                        if (code < 32 || code > 126) sb.AppendFormat("\\u{0:x4}", code);
                        else sb.Append(ch);
                        break;
                }
            }
            sb.Append('"');
            return sb.ToString();
        }

        public static string[] FindFreshManifests(string root, long minCreationFileTimeUtc)
        {
            if (string.IsNullOrEmpty(root) || !System.IO.Directory.Exists(root)) return new string[0];
            var list = new List<System.Collections.Generic.KeyValuePair<long, string>>();
            string[] dirs = System.IO.Directory.GetDirectories(root);
            for (int i = 0; i < dirs.Length; i++)
            {
                string mp = System.IO.Path.Combine(dirs[i], "manifest.json");
                var fi = new System.IO.FileInfo(mp);
                if (!fi.Exists) continue;
                long ft = fi.LastWriteTimeUtc.ToFileTimeUtc();
                if (ft >= minCreationFileTimeUtc)
                {
                    list.Add(new KeyValuePair<long, string>(ft, mp));
                }
            }
            if (list.Count == 0) return new string[0];
            list.Sort((a, b) => b.Key.CompareTo(a.Key));
            var res = new string[list.Count];
            for (int i = 0; i < list.Count; i++) res[i] = list[i].Value;
            return res;
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

            uint hc;
            if (GetProcessHandleCount(handle, out hc))
            {
                stats.HandleCount = unchecked((int)hc);
                stats.HandleCountOk = true;
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

        public static PidFastSample[] SampleAndProbe(int[] targetPids, string[] lastHealthyPrefixes, IntPtr[] handles, int probeTimeoutMs)
        {
            int n = targetPids == null ? 0 : targetPids.Length;
            var outArr = new PidFastSample[n];
            if (n == 0) return outArr;

            var winSamples = SamplePidWindows(targetPids, lastHealthyPrefixes);
            for (int i = 0; i < n; i++)
            {
                IntPtr h = (handles != null && i < handles.Length) ? handles[i] : IntPtr.Zero;
                int code = 0;
                bool readable = TryGetExitCode(h, out code);
                bool exited = readable && (code != STILL_ACTIVE);

                var ws = winSamples[i];
                bool isHung = false;
                bool probeOk = true;
                double latMs = 0.0;
                int winErr = 0;
                string title = ws.MainTitle ?? string.Empty;
                bool titleNr = false;

                if (ws.MainHwnd != IntPtr.Zero)
                {
                    var pr = ProbeWindow(ws.MainHwnd, probeTimeoutMs);
                    isHung = pr.IsHung;
                    probeOk = pr.ProbeOk;
                    latMs = pr.LatencyMs;
                    winErr = pr.Win32Error;
                    titleNr = title.IndexOf("(Not Responding)", StringComparison.OrdinalIgnoreCase) >= 0;
                }

                bool stall = (!probeOk) || isHung || ws.GhostMatched || titleNr;

                outArr[i] = new PidFastSample
                {
                    Pid = targetPids[i],
                    Exited = exited,
                    ExitCode = code,
                    ExitCodeReadable = readable,
                    MainHwnd = ws.MainHwnd,
                    MainTitle = title,
                    ModalTitles = ws.ModalTitles ?? new string[0],
                    GhostMatched = ws.GhostMatched,
                    IsHung = isHung,
                    ProbeOk = probeOk,
                    ProbeLatencyMs = latMs,
                    ProbeWin32Error = winErr,
                    TitleNr = titleNr,
                    Stall = stall,
                    Stats = null
                };
            }
            return outArr;
        }

        public static PollWakeResult PollUntilEvent(
            Stopwatch sessionSw,
            string targetExeLower,
            int targetPid,
            TrackedTargetSpec[] tracked,
            int pollIntervalMs,
            int probeTimeoutMs,
            double heartbeatMs,
            double maxDurationSeconds,
            double lastToolhelpMs,
            Dictionary<int, string[]> lastChildrenByPid,
            string beaconFile,
            bool hasMtRoot,
            string effectiveBatchRoot,
            bool batchStateNonEmpty)
        {
            int skippedTicks = 0;
            double enterMs = sessionSw.Elapsed.TotalMilliseconds;
            int n = tracked == null ? 0 : tracked.Length;
            int[] pids = new int[n];
            string[] prefixes = new string[n];
            IntPtr[] handles = new IntPtr[n];
            for (int i = 0; i < n; i++)
            {
                pids[i] = tracked[i].Pid;
                prefixes[i] = tracked[i].LastHealthyPrefix ?? string.Empty;
                handles[i] = tracked[i].Handle;
            }
            bool hasBeacon = !string.IsNullOrEmpty(beaconFile);
            bool hasBatch = !string.IsNullOrEmpty(effectiveBatchRoot);

            while (true)
            {
                double tickStartMs = sessionSw.Elapsed.TotalMilliseconds;
                if (maxDurationSeconds > 0 && (tickStartMs / 1000.0) >= maxDurationSeconds)
                {
                    return new PollWakeResult
                    {
                        HitMaxDuration = true,
                        DidToolhelp = false,
                        LastToolhelpMs = lastToolhelpMs,
                        TicksSampled = skippedTicks,
                        LiveTargetPids = null,
                        ChildrenByPid = lastChildrenByPid,
                        FastSamples = null,
                        WakeTickStartMs = tickStartMs
                    };
                }

                bool didToolhelp = ((tickStartMs - lastToolhelpMs) >= 1000.0) || (n == 0);
                int[] liveArr = null;
                if (didToolhelp)
                {
                    lastToolhelpMs = tickStartMs;
                    var tree = SnapshotTargetTree(targetExeLower, targetPid);
                    liveArr = tree.LiveTargetPids;
                    lastChildrenByPid = tree.ChildrenByPid;
                    if (liveArr != null)
                    {
                        for (int li = 0; li < liveArr.Length; li++)
                        {
                            if (Array.IndexOf(pids, liveArr[li]) < 0)
                            {
                                return new PollWakeResult
                                {
                                    HitMaxDuration = false,
                                    DidToolhelp = true,
                                    LastToolhelpMs = lastToolhelpMs,
                                    TicksSampled = skippedTicks,
                                    LiveTargetPids = liveArr,
                                    ChildrenByPid = lastChildrenByPid,
                                    FastSamples = null,
                                    WakeTickStartMs = tickStartMs
                                };
                            }
                        }
                    }
                }

                if (n == 0)
                {
                    if ((tickStartMs - enterMs) >= 2000.0)
                    {
                        return new PollWakeResult
                        {
                            HitMaxDuration = false,
                            DidToolhelp = didToolhelp,
                            LastToolhelpMs = lastToolhelpMs,
                            TicksSampled = skippedTicks,
                            LiveTargetPids = liveArr,
                            ChildrenByPid = lastChildrenByPid,
                            FastSamples = null,
                            WakeTickStartMs = tickStartMs
                        };
                    }
                    double tickEndEmpty = sessionSw.Elapsed.TotalMilliseconds;
                    int sleepEmptyMs = (int)Math.Ceiling(Math.Max(tickStartMs + pollIntervalMs, tickEndEmpty) - tickEndEmpty);
                    if (sleepEmptyMs > 0)
                    {
                        System.Threading.Thread.Sleep(sleepEmptyMs);
                    }
                    continue;
                }

                PidFastSample[] samples = SampleAndProbe(pids, prefixes, handles, probeTimeoutMs);
                string bStamp = string.Empty;
                if (hasBeacon)
                {
                    var bfi = new System.IO.FileInfo(beaconFile);
                    if (bfi.Exists)
                    {
                        bStamp = bfi.Length.ToString() + ":" + bfi.LastWriteTimeUtc.Ticks.ToString();
                    }
                }

                double nowMono = Math.Round(sessionSw.Elapsed.TotalMilliseconds, 1);
                bool wake = false;
                for (int i = 0; i < samples.Length; i++)
                {
                    var fs = samples[i];
                    var sp = tracked[i];
                    bool exited = fs.Exited || (didToolhelp && liveArr != null && Array.IndexOf(liveArr, fs.Pid) < 0);
                    if (exited || fs.Stall || sp.HealthyAfterStallLeft > 0)
                    {
                        wake = true;
                        break;
                    }
                    if (sp.PrevTitle == null || !string.Equals(sp.PrevTitle, fs.MainTitle, StringComparison.Ordinal))
                    {
                        wake = true;
                        break;
                    }
                    string modalKey = (fs.ModalTitles == null || fs.ModalTitles.Length == 0) ? string.Empty : string.Join("\n", fs.ModalTitles);
                    if (sp.PrevModalKey == null || !string.Equals(sp.PrevModalKey, modalKey, StringComparison.Ordinal))
                    {
                        wake = true;
                        break;
                    }
                    if (didToolhelp || sp.PrevChildrenKey == null)
                    {
                        string[] cArr = null;
                        if (lastChildrenByPid != null)
                        {
                            lastChildrenByPid.TryGetValue(fs.Pid, out cArr);
                        }
                        string childrenKey = (cArr == null || cArr.Length == 0) ? string.Empty : string.Join("\n", cArr);
                        if (sp.PrevChildrenKey == null || !string.Equals(sp.PrevChildrenKey, childrenKey, StringComparison.Ordinal))
                        {
                            wake = true;
                            break;
                        }
                    }
                    if (hasBeacon && !string.Equals(bStamp, sp.LastBeaconStamp, StringComparison.Ordinal))
                    {
                        wake = true;
                        break;
                    }
                    if (didToolhelp)
                    {
                        if (sp.ForcePhaseCheckOnToolhelp || hasMtRoot)
                        {
                            wake = true;
                            break;
                        }
                        if (hasBatch)
                        {
                            if (batchStateNonEmpty || FindFreshManifests(effectiveBatchRoot, sp.CreationFileTimeUtc).Length > 0)
                            {
                                wake = true;
                                break;
                            }
                        }
                    }
                    if ((nowMono - sp.LastWrittenMonoMs) >= heartbeatMs)
                    {
                        wake = true;
                        break;
                    }
                }

                if (wake)
                {
                    return new PollWakeResult
                    {
                        HitMaxDuration = false,
                        DidToolhelp = didToolhelp,
                        LastToolhelpMs = lastToolhelpMs,
                        TicksSampled = skippedTicks,
                        LiveTargetPids = liveArr,
                        ChildrenByPid = lastChildrenByPid,
                        FastSamples = samples,
                        WakeTickStartMs = tickStartMs
                    };
                }

                skippedTicks += samples.Length;
                double tickEndMs = sessionSw.Elapsed.TotalMilliseconds;
                int sleepMs = (int)Math.Ceiling(Math.Max(tickStartMs + pollIntervalMs, tickEndMs) - tickEndMs);
                if (sleepMs > 0)
                {
                    System.Threading.Thread.Sleep(sleepMs);
                }
            }
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
        return [Sibambo.SkpWatchdog.Native]::JsonEscape($Val)
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

function Read-SharedFileTextIfChanged {
    param([string]$Path, [hashtable]$FileCache)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $fi = [System.IO.FileInfo]::new($Path)
    if (-not $fi.Exists) {
        if ($null -ne $FileCache -and $FileCache.ContainsKey($Path)) {
            $FileCache.Remove($Path)
        }
        return $null
    }
    $stamp = "$($fi.LastWriteTimeUtc.Ticks):$($fi.Length)"
    if ($null -ne $FileCache -and $FileCache.ContainsKey($Path)) {
        $entry = $FileCache[$Path]
        if ($entry.Stamp -eq $stamp) {
            return $entry.Text
        }
    }
    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
    try {
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $true)
        try {
            $text = $sr.ReadToEnd()
        }
        finally {
            $sr.Dispose()
        }
    }
    finally {
        $fs.Dispose()
    }
    if ($null -ne $FileCache) {
        $FileCache[$Path] = @{ Stamp = $stamp; Text = $text }
    }
    return $text
}

function Get-EffectiveBatchRoot {
    param([string]$BeaconPath, [string]$BatchRoot, [bool]$BatchRootBound)
    if (-not [string]::IsNullOrWhiteSpace($BeaconPath) -and -not $BatchRootBound) {
        return ""
    }
    return $BatchRoot
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
    $handles = if ($pStats.HandleCountOk) { $pStats.HandleCount } else { $null }
    return @{
        working_set_mib = if ($pStats.MemoryOk) { $pStats.WorkingSetMiB } else { $null }
        private_mib = if ($pStats.MemoryOk) { $pStats.PrivateMiB } else { $null }
        cpu_user_ms = if ($pStats.TimesOk) { $pStats.CpuUserMs } else { $null }
        cpu_kernel_ms = if ($pStats.TimesOk) { $pStats.CpuKernelMs } else { $null }
        handles = $handles
        gdi = if ($pStats.GdiOk) { $pStats.GdiObjects } else { $null }
        user = if ($pStats.UserOk) { $pStats.UserObjects } else { $null }
    }
}

function Get-ModelTruthCandidates {
    param([string]$Root, [hashtable]$FileCache)
    $list = @()
    if ([string]::IsNullOrWhiteSpace($Root) -or -not [System.IO.Directory]::Exists($Root)) { return ,$list }
    try {
        $files = Get-ChildItem -LiteralPath $Root -Filter "progress.json" -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { (Split-Path $_.DirectoryName -Leaf) -eq "skp" } |
            Sort-Object LastWriteTimeUtc -Descending
        foreach ($f in $files) {
            try {
                $raw = Read-SharedFileTextIfChanged -Path $f.FullName -FileCache $FileCache
                if ([string]::IsNullOrEmpty($raw)) { continue }
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
    if ($null -eq $Candidates) { return @{ State = "none"; Match = $null } }
    $fresh = @()
    foreach ($cand in @($Candidates)) {
        if ($cand.LastWriteTimeUtc -ge $CreationUtc) {
            $fresh += $cand
        }
    }
    if ($fresh.Count -eq 0) { return @{ State = "none"; Match = $null } }
    if ($fresh.Count -gt 1) { return @{ State = "ambiguous"; Match = $null } }
    return @{
        State = "single"
        Match = @{
            phase_group = "skp_capture"
            phase_source = "model_truth"
            model = $fresh[0].Model
        }
    }
}

function Resolve-BatchRoot {
    param([string]$Root, [datetime]$MinCreationUtc, [hashtable]$FileCache)
    if ([string]::IsNullOrWhiteSpace($Root)) {
        return @{ State = "none"; Match = $null }
    }
    try {
        $freshPaths = [Sibambo.SkpWatchdog.Native]::FindFreshManifests($Root, $MinCreationUtc.ToFileTimeUtc())
        if ($null -eq $freshPaths -or $freshPaths.Length -eq 0) {
            return @{ State = "none"; Match = $null }
        }

        $activeMatches = @()
        foreach ($mfPath in $freshPaths) {
            try {
                $raw = Read-SharedFileTextIfChanged -Path $mfPath -FileCache $FileCache
                if ([string]::IsNullOrEmpty($raw)) { continue }
                $man = $raw | ConvertFrom-Json
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

                $tempDirPath = [System.IO.Path]::Combine($attemptDir, "temp")
                if ($curStage -eq "OPEN_SKP" -and -not [System.IO.Directory]::Exists($tempDirPath)) {
                    $pg = "batch_open_skp"
                }
                else {
                    $pg = "batch_export"
                }
                $activeMatches += @{
                    phase_group = $pg
                    phase_source = "batch"
                    model = $curModel
                    last_write_utc = [System.IO.File]::GetLastWriteTimeUtc($mfPath)
                }
            }
            catch { }
        }
        if ($activeMatches.Count -eq 0) { return @{ State = "none"; Match = $null } }
        if ($activeMatches.Count -gt 1) { return @{ State = "ambiguous"; Match = $null } }
        return @{ State = "single"; Match = $activeMatches[0] }
    }
    catch { }
    return @{ State = "none"; Match = $null }
}

function Resolve-Phase {
    param(
        [hashtable]$ProcState,
        [string]$BeaconPath,
        [string]$ModelTruthRoot,
        [string]$BatchRoot,
        [hashtable]$Cache,
        [int]$ActiveTargetCount = 1,
        [int]$ProgressStaleSeconds = 120,
        [System.Diagnostics.Stopwatch]$SessionSw = $null
    )

    $emitted = @()
    $nowMono = if ($null -ne $SessionSw) { [Math]::Round($SessionSw.Elapsed.TotalMilliseconds, 1) } else { [double]$Cache.NowMs }
    $fileCache = if ($Cache.ContainsKey("FileCache")) { $Cache.FileCache } else { @{} }
    if (-not $ProcState.ContainsKey("LastLifecycleSeq")) { $ProcState.LastLifecycleSeq = 0 }
    if (-not $ProcState.ContainsKey("LifecycleStatuses")) { $ProcState.LifecycleStatuses = @{} }
    if (-not $ProcState.ContainsKey("CaptureTerminalEmitted")) { $ProcState.CaptureTerminalEmitted = $false }
    if (-not $ProcState.ContainsKey("LastProgCheckMs")) { $ProcState.LastProgCheckMs = -10000.0 }
    if (-not $ProcState.ContainsKey("LastProgMtimeTicks")) { $ProcState.LastProgMtimeTicks = -1L }
    if (-not $ProcState.ContainsKey("LastProgChangeMonoMs")) { $ProcState.LastProgChangeMonoMs = $nowMono }
    if (-not $ProcState.ContainsKey("StallWarningEmitted")) { $ProcState.StallWarningEmitted = $false }

    # 1. Beacon (stat-first shared read; unambiguous per-PID ownership)
    if (-not [string]::IsNullOrWhiteSpace($BeaconPath)) {
        try {
            $rawBeacon = Read-SharedFileTextIfChanged -Path $BeaconPath -FileCache $fileCache
            if (-not [string]::IsNullOrEmpty($rawBeacon)) {
                $b = $rawBeacon | ConvertFrom-Json
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
                        $bSkpSha = [string](Get-JsonProp $b "skp_sha256")
                        $bTimings = Get-JsonProp $b "stage_timings_ms"

                        # D50: emit unseen or completed lifecycle entries without fabricating tick lines
                        $lcRaw = Get-JsonProp $b "lifecycle"
                        if ($null -ne $lcRaw) {
                            $lcList = @($lcRaw) | Sort-Object { [int](Get-JsonProp $_ "seq") }
                            foreach ($lc in $lcList) {
                                $lSeq = [int](Get-JsonProp $lc "seq")
                                $lStatus = [string](Get-JsonProp $lc "status")
                                $prevLStatus = if ($ProcState.LifecycleStatuses.ContainsKey($lSeq)) { $ProcState.LifecycleStatuses[$lSeq] } else { $null }
                                if ($lSeq -gt $ProcState.LastLifecycleSeq -or $prevLStatus -ne $lStatus) {
                                    $ProcState.LifecycleStatuses[$lSeq] = $lStatus
                                    if ($lSeq -gt $ProcState.LastLifecycleSeq) { $ProcState.LastLifecycleSeq = $lSeq }
                                    $lDur = Get-JsonProp $lc "duration_ms"
                                    $lTimingsHash = $null
                                    if ($null -ne $bTimings) {
                                        $lTimingsHash = @{}
                                        foreach ($prop in $bTimings.PSObject.Properties) {
                                            $lTimingsHash[$prop.Name] = $prop.Value
                                        }
                                    }
                                    $emitted += @{
                                        type = "beacon_lifecycle"
                                        utc = (Get-UtcIso)
                                        mono_ms = $nowMono
                                        pid = $ProcState.Pid
                                        seq = $lSeq
                                        phase_group = [string](Get-JsonProp $lc "phase_group")
                                        status = $lStatus
                                        model = $model
                                        started_utc = (Get-JsonProp $lc "started_utc")
                                        ended_utc = (Get-JsonProp $lc "ended_utc")
                                        duration_ms = $lDur
                                        stage_timings_ms = $lTimingsHash
                                        error = (Get-JsonProp $lc "error")
                                    }
                                }
                            }
                        }

                        # D49: Authoritative capture completion via skp/manifest.json (zero progress.json handle opens!)
                        if ($pg -eq "skp_capture" -and -not [string]::IsNullOrWhiteSpace($bRunDir)) {
                            $manPath = [System.IO.Path]::Combine($bRunDir, "skp\manifest.json")
                            $manFi = [System.IO.FileInfo]::new($manPath)
                            if ($manFi.Exists -and $manFi.LastWriteTimeUtc -ge $ProcState.CreationUtc) {
                                try {
                                    $rawMan = Read-SharedFileTextIfChanged -Path $manPath -FileCache $fileCache
                                    if (-not [string]::IsNullOrEmpty($rawMan)) {
                                        $manObj = $rawMan | ConvertFrom-Json
                                        $manSide = [string](Get-JsonProp $manObj "side")
                                        $manComplete = Get-JsonProp $manObj "complete"
                                        $manInputs = Get-JsonProp $manObj "inputs"
                                        $manSha = [string](Get-JsonProp $manInputs "skp_sha256")
                                        $shaValid = ([string]::IsNullOrEmpty($bSkpSha) -or $manComplete -ne $true -or [string]::IsNullOrEmpty($manSha) -or $manSha.ToLowerInvariant() -eq $bSkpSha.ToLowerInvariant())
                                        if ($manSide -eq "skp" -and ($manComplete -is [bool]) -and $shaValid) {
                                            $pg = "idle"
                                            if (-not $ProcState.CaptureTerminalEmitted) {
                                                $ProcState.CaptureTerminalEmitted = $true
                                                $manErr = Get-JsonProp $manObj "error"
                                                $errStr = $null
                                                if ($null -ne $manErr) {
                                                    if ($manErr -is [string]) { $errStr = $manErr }
                                                    else { $errStr = "$(Get-JsonProp $manErr 'class'): $(Get-JsonProp $manErr 'message')" }
                                                }
                                                $emitted += @{
                                                    type = "capture_terminal"
                                                    utc = (Get-UtcIso)
                                                    mono_ms = $nowMono
                                                    pid = $ProcState.Pid
                                                    run_dir = $bRunDir
                                                    complete = [bool]$manComplete
                                                    manifest_path = $manPath
                                                    error = $errStr
                                                }
                                            }
                                        }
                                    }
                                }
                                catch { }
                            }
                            elseif ($ProgressStaleSeconds -gt 0 -and ($nowMono - $ProcState.LastProgCheckMs) -ge 5000.0) {
                                # D53: Stat-only progress.json liveness check (0 handles opened)
                                $ProcState.LastProgCheckMs = $nowMono
                                $progPath = [System.IO.Path]::Combine($bRunDir, "skp\progress.json")
                                $progFi = [System.IO.FileInfo]::new($progPath)
                                if ($progFi.Exists) {
                                    $ticks = $progFi.LastWriteTimeUtc.Ticks
                                    if ($ProcState.LastProgMtimeTicks -ne $ticks) {
                                        $ProcState.LastProgMtimeTicks = $ticks
                                        $ProcState.LastProgChangeMonoMs = $nowMono
                                        $ProcState.StallWarningEmitted = $false
                                    }
                                    else {
                                        $staleSec = [Math]::Round(($nowMono - $ProcState.LastProgChangeMonoMs) / 1000.0, 1)
                                        if ($staleSec -ge $ProgressStaleSeconds -and -not $ProcState.StallWarningEmitted) {
                                            $ProcState.StallWarningEmitted = $true
                                            $lastIso = $progFi.LastWriteTimeUtc.ToString("yyyy-MM-ddTHH:mm:ss.fffZ", [System.Globalization.CultureInfo]::InvariantCulture)
                                            [Console]::Error.WriteLine("WARN: capture progress.json mtime stalled for ${staleSec}s at $progPath")
                                            $emitted += @{
                                                type = "capture_progress_stalled"
                                                utc = (Get-UtcIso)
                                                mono_ms = $nowMono
                                                pid = $ProcState.Pid
                                                run_dir = $bRunDir
                                                stale_seconds = $staleSec
                                                last_progress_utc = $lastIso
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        $ProcState.HasBeenAttributed = $true
                        return @{ phase_group = $pg; phase_source = "beacon"; model = $model; events = $emitted }
                    }
                }
            }
        }
        catch { }
    }

    $nowMs = $Cache.NowMs
    # 2. ModelTruth root (scanned every 1000 ms; stat-cached)
    $mtRes = @{ State = "none"; Match = $null }
    if (-not [string]::IsNullOrWhiteSpace($ModelTruthRoot)) {
        if (($nowMs - $Cache.LastMtScanMs) -ge 1000.0 -or -not $Cache.MtScanned) {
            $Cache.LastMtScanMs = $nowMs
            $Cache.MtScanned = $true
            $Cache.MtCandidates = Get-ModelTruthCandidates -Root $ModelTruthRoot -FileCache $fileCache
        }
        $mtRes = Resolve-ModelTruthFromCandidates -Candidates $Cache.MtCandidates -CreationUtc $ProcState.CreationUtc
    }

    # 3. Batch root (scanned every 1000 ms; stat-only freshness filter + FileShare.Delete cache)
    $batchRes = @{ State = "none"; Match = $null }
    if (-not [string]::IsNullOrWhiteSpace($BatchRoot)) {
        if (($nowMs - $Cache.LastBatchScanMs) -ge 1000.0 -or -not $Cache.BatchScanned) {
            $Cache.LastBatchScanMs = $nowMs
            $Cache.BatchScanned = $true
            $Cache.BatchResult = Resolve-BatchRoot -Root $BatchRoot -MinCreationUtc $ProcState.CreationUtc -FileCache $fileCache
        }
        $batchRes = $Cache.BatchResult
        if ($batchRes.State -eq "single" -and $batchRes.Match.last_write_utc -lt $ProcState.CreationUtc) {
            $batchRes = @{ State = "none"; Match = $null }
        }
    }

    # Multi-PID or ambiguous concurrent runs fail closed to unattributed (UNKNOWN)
    if ($ActiveTargetCount -gt 1) {
        if ($mtRes.State -ne "none" -or $batchRes.State -ne "none") {
            return @{ phase_group = "unattributed"; phase_source = "none"; model = $null; events = $emitted }
        }
    }
    else {
        if ($mtRes.State -eq "single") {
            $ProcState.HasBeenAttributed = $true
            return @{ phase_group = $mtRes.Match.phase_group; phase_source = $mtRes.Match.phase_source; model = $mtRes.Match.model; events = $emitted }
        }
        if ($mtRes.State -eq "ambiguous") {
            return @{ phase_group = "unattributed"; phase_source = "none"; model = $null; events = $emitted }
        }
        if ($batchRes.State -eq "single") {
            $ProcState.HasBeenAttributed = $true
            return @{ phase_group = $batchRes.Match.phase_group; phase_source = $batchRes.Match.phase_source; model = $batchRes.Match.model; events = $emitted }
        }
        if ($batchRes.State -eq "ambiguous") {
            return @{ phase_group = "unattributed"; phase_source = "none"; model = $null; events = $emitted }
        }
    }

    # 4. Startup
    if (-not $ProcState.HasBeenAttributed) {
        return @{ phase_group = "startup"; phase_source = "startup"; model = $null; events = $emitted }
    }

    # 5. Unattributed
    return @{ phase_group = "unattributed"; phase_source = "none"; model = $null; events = $emitted }
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

    $batchRootBound = $PSBoundParameters.ContainsKey('WatchBatchRoot')
    $effectiveBatchRoot = Get-EffectiveBatchRoot -BeaconPath $BeaconFile -BatchRoot $WatchBatchRoot -BatchRootBound $batchRootBound

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
                batch_root = $effectiveBatchRoot
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
            BatchResult = @{ State = "none"; Match = $null }
            FileCache = @{}
        }

        $targetExeLower = if ($ProcessName.ToLowerInvariant().EndsWith(".exe")) {
            $ProcessName.ToLowerInvariant()
        }
        else {
            ($ProcessName + ".exe").ToLowerInvariant()
        }

        $hasBeaconFile = -not [string]::IsNullOrWhiteSpace($BeaconFile)
        $hasMtRoot = -not [string]::IsNullOrWhiteSpace($WatchModelTruthRoot)
        $hasBatchRoot = -not [string]::IsNullOrWhiteSpace($effectiveBatchRoot)
        $heartbeatMs = $HeartbeatSeconds * 1000.0
        $lastToolhelpMs = -2000.0
        $lastChildrenByPid = New-Object 'System.Collections.Generic.Dictionary[int, string[]]'

        while ($true) {
            $nSpec = $tracked.Count
            $specs = New-Object 'Sibambo.SkpWatchdog.TrackedTargetSpec[]' $nSpec
            $si = 0
            foreach ($kv in $tracked.GetEnumerator()) {
                $stItem = $kv.Value
                $lt = $stItem.LastHealthyTitle
                $sp = New-Object 'Sibambo.SkpWatchdog.TrackedTargetSpec'
                $sp.Pid = $kv.Key
                $sp.Handle = $stItem.Handle
                $sp.CreationFileTimeUtc = $stItem.CreationUtc.ToFileTimeUtc()
                $sp.LastHealthyPrefix = if ([string]::IsNullOrEmpty($lt)) { "" } else { $lt.Substring(0, [Math]::Min(40, $lt.Length)) }
                $sp.PrevTitle = $stItem.PrevTitle
                $sp.PrevModalKey = $stItem.PrevModalKey
                $sp.PrevChildrenKey = $stItem.PrevChildrenKey
                $sp.HealthyAfterStallLeft = $stItem.HealthyAfterStallLeft
                $sp.LastWrittenMonoMs = $stItem.LastWrittenMonoMs
                $sp.ForcePhaseCheckOnToolhelp = ($null -eq $stItem.PrevPhaseGroup -or $stItem.PrevPhaseGroup -eq "skp_capture")
                $sp.LastBeaconStamp = $stItem.LastBeaconStamp
                $specs[$si] = $sp
                $si++
            }

            $wake = [Sibambo.SkpWatchdog.Native]::PollUntilEvent(
                $sessionSw, $targetExeLower, $TargetPid, $specs,
                $PollIntervalMs, $ProbeTimeoutMs, $heartbeatMs, [double]$MaxDurationSeconds,
                $lastToolhelpMs, $lastChildrenByPid, $BeaconFile, $hasMtRoot, $effectiveBatchRoot,
                ($scanCache.BatchResult.State -ne "none")
            )

            $ticksTotal += $wake.TicksSampled
            $lastToolhelpMs = $wake.LastToolhelpMs
            $lastChildrenByPid = $wake.ChildrenByPid
            $tickStartMs = $wake.WakeTickStartMs
            $scanCache.NowMs = $tickStartMs
            $didToolhelp = $wake.DidToolhelp
            $liveArr = $wake.LiveTargetPids

            if ($wake.HitMaxDuration) {
                $endReason = "max_duration"
                break
            }

            if ($didToolhelp -and ($null -ne $liveArr)) {
                foreach ($tPid in $liveArr) {
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
                            $imgPath = $targetExeLower
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
                            PrevPhaseSource = "startup"
                            PrevModel = $null
                            LastBeaconStamp = ""
                            PrevTitle = $null
                            PrevModalKey = $null
                            PrevChildrenKey = $null
                            LastChildrenArr = @()
                            LastLifecycleSeq = 0
                            LifecycleStatuses = @{}
                            CaptureTerminalEmitted = $false
                            LastProgCheckMs = -10000.0
                            LastProgMtimeTicks = -1L
                            LastProgChangeMonoMs = $tickStartMs
                            StallWarningEmitted = $false
                        }

                        Write-EventLine @{
                            type = "process_started"
                            utc = (Get-UtcIso)
                            mono_ms = [Math]::Round($sessionSw.Elapsed.TotalMilliseconds, 1)
                            pid = $tPid
                            creation_utc = $cUtc.ToString("yyyy-MM-ddTHH:mm:ss.fffZ", [System.Globalization.CultureInfo]::InvariantCulture)
                            image_path = $imgPath
                        }
                    }
                }
            }

            if ($tracked.Count -gt 0) {
                $fastSamples = $wake.FastSamples
                if ($null -eq $fastSamples) {
                    $nTracked = $tracked.Count
                    $pidArr = New-Object int[] $nTracked
                    $prefixes = New-Object string[] $nTracked
                    $handleArr = New-Object IntPtr[] $nTracked
                    $ti = 0
                    foreach ($kv in $tracked.GetEnumerator()) {
                        $stItem = $kv.Value
                        $pidArr[$ti] = $kv.Key
                        $handleArr[$ti] = $stItem.Handle
                        $lt = $stItem.LastHealthyTitle
                        $prefixes[$ti] = if ([string]::IsNullOrEmpty($lt)) { "" } else { $lt.Substring(0, [Math]::Min(40, $lt.Length)) }
                        $ti++
                    }
                    $fastSamples = [Sibambo.SkpWatchdog.Native]::SampleAndProbe($pidArr, $prefixes, $handleArr, $ProbeTimeoutMs)
                }
                foreach ($fs in $fastSamples) {
                    $tPid = $fs.Pid
                    $st = $tracked[$tPid]
                    $exited = $fs.Exited -or ($didToolhelp -and ($null -ne $liveArr) -and ([Array]::IndexOf($liveArr, $tPid) -lt 0))
                    if ($exited) {
                        [Sibambo.SkpWatchdog.Native]::CloseTargetHandle($st.Handle)
                        $tracked.Remove($tPid)
                        Write-EventLine @{
                            type = "process_exited"
                            utc = (Get-UtcIso)
                            mono_ms = [Math]::Round($sessionSw.Elapsed.TotalMilliseconds, 1)
                            pid = $tPid
                            exit_code = if ($fs.ExitCodeReadable) { $fs.ExitCode } else { $null }
                            exit_code_readable = $fs.ExitCodeReadable
                        }
                        continue
                    }

                    $ticksTotal++
                    $mainHwndHex = if ($fs.MainHwnd -ne [IntPtr]::Zero) { "0x" + $fs.MainHwnd.ToInt64().ToString("x") } else { $null }
                    $probeOk = $fs.ProbeOk
                    $probeLatencyMs = $fs.ProbeLatencyMs
                    $probeErr = if ($probeOk) { $null } else { $fs.ProbeWin32Error }
                    $isHung = $fs.IsHung
                    $title = $fs.MainTitle
                    $titleNr = $fs.TitleNr
                    $ghost = $fs.GhostMatched
                    $modalTitles = $fs.ModalTitles
                    $modalKey = if ($null -eq $modalTitles -or $modalTitles.Length -eq 0) { "" } else { $modalTitles -join "`n" }
                    $stall = $fs.Stall
                    if (-not $stall -and -not [string]::IsNullOrEmpty($title)) {
                        $st.LastHealthyTitle = $title
                    }

                    # D44/D48/D49/D50/D53 Phase attribution (gated to avoid idle PowerShell work)
                    $bStamp = ""
                    if ($hasBeaconFile) {
                        $bfi = [System.IO.FileInfo]::new($BeaconFile)
                        if ($bfi.Exists) {
                            $bStamp = "$($bfi.Length):$($bfi.LastWriteTimeUtc.Ticks)"
                        }
                    }
                    $beaconChanged = ($bStamp -ne $st.LastBeaconStamp)
                    $needPhase = ($null -eq $st.PrevPhaseGroup) -or $beaconChanged -or ($didToolhelp -and ($st.PrevPhaseGroup -eq "skp_capture" -or $hasMtRoot))
                    if (-not $needPhase -and $hasBatchRoot -and $didToolhelp) {
                        if ($scanCache.BatchResult.State -ne "none" -or ([Sibambo.SkpWatchdog.Native]::FindFreshManifests($effectiveBatchRoot, $st.CreationUtc.ToFileTimeUtc())).Length -gt 0) {
                            $needPhase = $true
                        }
                    }

                    $eventWrittenThisTick = $false
                    if ($needPhase) {
                        $st.LastBeaconStamp = $bStamp
                        $phaseInfo = Resolve-Phase -ProcState $st -BeaconPath $BeaconFile -ModelTruthRoot $WatchModelTruthRoot -BatchRoot $effectiveBatchRoot -Cache $scanCache -ActiveTargetCount $tracked.Count -ProgressStaleSeconds $ProgressStaleSeconds -SessionSw $sessionSw
                        $phaseGroup = $phaseInfo.phase_group
                        $phaseSource = $phaseInfo.phase_source
                        $modelVal = $phaseInfo.model
                        $st.PrevPhaseSource = $phaseSource
                        $st.PrevModel = $modelVal
                        if ($phaseInfo.events.Count -gt 0) {
                            foreach ($ev in $phaseInfo.events) {
                                Write-EventLine $ev
                                $eventWrittenThisTick = $true
                            }
                        }
                    }
                    else {
                        $phaseGroup = $st.PrevPhaseGroup
                        $phaseSource = $st.PrevPhaseSource
                        $modelVal = $st.PrevModel
                    }

                    # D43 Change events
                    if ($null -ne $st.PrevPhaseGroup -and $st.PrevPhaseGroup -ne $phaseGroup) {
                        Write-EventLine @{
                            type = "phase_changed"
                            utc = (Get-UtcIso)
                            mono_ms = [Math]::Round($sessionSw.Elapsed.TotalMilliseconds, 1)
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
                            mono_ms = [Math]::Round($sessionSw.Elapsed.TotalMilliseconds, 1)
                            pid = $tPid
                            title = $title
                        }
                        $eventWrittenThisTick = $true
                    }
                    $st.PrevTitle = $title

                    $modalChanged = ($null -ne $st.PrevModalKey -and $st.PrevModalKey -ne $modalKey)
                    $st.PrevModalKey = $modalKey

                    $childrenArr = $st.LastChildrenArr
                    if ($didToolhelp -or ($null -eq $st.PrevChildrenKey)) {
                        $childrenArr = @()
                        if ($null -ne $lastChildrenByPid -and $lastChildrenByPid.ContainsKey($tPid)) {
                            $childrenArr = $lastChildrenByPid[$tPid]
                        }
                        $childrenKey = if ($childrenArr.Length -eq 0) { "" } else { $childrenArr -join "`n" }
                        if ($null -ne $st.PrevChildrenKey -and $st.PrevChildrenKey -ne $childrenKey) {
                            Write-EventLine @{
                                type = "children_changed"
                                utc = (Get-UtcIso)
                                mono_ms = [Math]::Round($sessionSw.Elapsed.TotalMilliseconds, 1)
                                pid = $tPid
                                children = $childrenArr
                            }
                            $eventWrittenThisTick = $true
                        }
                        $st.PrevChildrenKey = $childrenKey
                        $st.LastChildrenArr = $childrenArr
                    }

                    # D43 Tick write policy
                    $nowMonoMs = [Math]::Round($sessionSw.Elapsed.TotalMilliseconds, 1)
                    $shouldWriteTick = $false
                    if ($stall) {
                        $st.HealthyAfterStallLeft = 2
                        $shouldWriteTick = $true
                    }
                    elseif ($st.HealthyAfterStallLeft -gt 0) {
                        $st.HealthyAfterStallLeft--
                        $shouldWriteTick = $true
                    }
                    if ($eventWrittenThisTick -or $modalChanged) {
                        $shouldWriteTick = $true
                    }
                    if (($nowMonoMs - $st.LastWrittenMonoMs) -ge $heartbeatMs) {
                        $shouldWriteTick = $true
                    }

                    if ($modalChanged -or $shouldWriteTick) {
                        $modalArr = if ($null -eq $modalTitles -or $modalTitles.Length -eq 0) {
                            @()
                        }
                        else {
                            $mOut = New-Object object[] $modalTitles.Length
                            for ($mi = 0; $mi -lt $modalTitles.Length; $mi++) {
                                $mOut[$mi] = @{ class = "#32770"; title = $modalTitles[$mi] }
                            }
                            $mOut
                        }
                        if ($modalChanged) {
                            Write-EventLine @{
                                type = "modal_changed"
                                utc = (Get-UtcIso)
                                mono_ms = [Math]::Round($sessionSw.Elapsed.TotalMilliseconds, 1)
                                pid = $tPid
                                modal = $modalArr
                            }
                        }
                    }

                    if ($shouldWriteTick) {
                        $ps = [Sibambo.SkpWatchdog.Native]::GetProcStats($st.Handle)
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
                            working_set_mib = if ($ps.MemoryOk) { $ps.WorkingSetMiB } else { $null }
                            private_mib = if ($ps.MemoryOk) { $ps.PrivateMiB } else { $null }
                            cpu_user_ms = if ($ps.TimesOk) { $ps.CpuUserMs } else { $null }
                            cpu_kernel_ms = if ($ps.TimesOk) { $ps.CpuKernelMs } else { $null }
                            handles = if ($ps.HandleCountOk) { $ps.HandleCount } else { $null }
                            gdi = if ($ps.GdiOk) { $ps.GdiObjects } else { $null }
                            user = if ($ps.UserOk) { $ps.UserObjects } else { $null }
                            children = $childrenArr
                        }
                    }
                }
            }

            if ($ExitWhenTargetExits -and $seenAnyTarget -and $tracked.Count -eq 0) {
                $endReason = "target_exited"
                break
            }

            $tickEndMs = $sessionSw.Elapsed.TotalMilliseconds
            $sleepMs = [int][Math]::Ceiling([Math]::Max($tickStartMs + $PollIntervalMs, $tickEndMs) - $tickEndMs)
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
