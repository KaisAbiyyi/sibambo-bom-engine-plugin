# Native resource and per-stage trace for candidate013 successor

Run the resource sampler outside SketchUp. It writes only to D: and never
opens, changes or re-saves a source SKP.

From Windows PowerShell in this repository:

~~~powershell
Get-Process SketchUp | Select-Object Id, ProcessName, StartTime
# Replace 12345 with the actual SketchUp PID:
powershell.exe -NoProfile -File .\tools\performance\watch_windows_resources.ps1 -ProcessId 12345 -IntervalSeconds 3 -DurationSeconds 1800
~~~

Begin the native RUMAH I Exact export after the monitor has written its start
record. Ctrl+C the monitor when export completes or allow the chosen duration
to expire. Preserve the generated JSONL and the BOMC performance sidecar.
Join the resource data to named stages using the *actual* saved paths:

~~~powershell
node .\tools\performance\join_resource_trace.js "D:\SibamboExports\I-NEW\model.bomc.performance.json" "D:\projects\sibambo\scratch\resource-traces\sketchup-12345-YYYYMMDD-HHMMSS.jsonl" "D:\projects\sibambo\scratch\resource-traces\I-NEW-joined.json"
~~~

Those filenames are illustrative. The sidecar must contain started_utc,
finished_utc and named stages with started_ms / finished_ms, which are relative
to the beginning of the export. All stage times are inclusive; nested stages
cannot be added as independent wall-time totals.

Recordings include Windows CPU total/per-core, SketchUp process cumulative
CPU time, RAM free/commit, process working/private memory, GPU Engine
utilization by PID, physical disk total throughput/queue, sample wall overhead
and sampler CPU use. GPU engine sums do **not** equal normalized entire-card
utilization. Physical disk _Total is an aggregate across drives, not D: only.
Missing counters or stage samples are null/unknown rather than zero.

For performance comparisons record SketchUp version and PID, installed E4
source SHA, saved SKP SHA, output SHA, device/background load, driver and
profile settings, plus cold/warm run identity. The old 012/013 wall times alone
do not establish which engine is faster. Native elapsed, maximum UI Fiber
slice and heartbeat thresholds, source fidelity and byte-size acceptance stay
unchanged. Monitoring overhead itself must be reported in every comparison.
