# SIB-PERF-GPU-00 — Windows export attribution

This is a **diagnostic** for the installed SketchUp Evolution exporter. It does not modify producer Ruby, load private SKP input, change Windows graphics preferences, or claim an export speedup. All output defaults to D:\projects\sibambo\scratch\perf-gpu-00.

## Provenance and ownership

Before measuring an export, confirm the **exclusive SketchUp host claim**: SIB-PERF-GPU-00 cannot share the host with SIB-SIZE-01, F1J native qualification, or a human currently using SketchUp. If SketchUp is running under an unknown owner, stop at Snapshot. Do not close, restart, or take over that session.

The diagnostic requires a saved private SKP on D:, the current install receipt, and its matching RBZ. The collector SHA-256 hashes each input and checks both installed BUILD_SHA.txt markers against the receipt; it refuses real capture on mismatched pins. Matching disk installation is **not** proof of a loaded Ruby runtime. The operator must start a new SketchUp session and verify the loaded build independently.

From the producer worktree in Windows PowerShell:

    $install = 'D:\projects\sibambo\outputs\2026-10-22-sib-size-01-candidate-004\install-report.json'
    $rbz = 'D:\projects\sibambo\outputs\2026-10-22-sib-size-01-candidate-004\sibambo_bom_engine_evolution_lineup.rbz'
    $probe = 'tools\performance\windows_gpu_export_probe.ps1'
    & $probe -Mode Snapshot -RunId preflight_unique_01 -InstallReceipt $install -PackageRbz $rbz

Run IDs must be unique. The tool refuses to overwrite an existing diagnostic directory. No private model, raw output, or host trace may be committed.

## Capture a representative export

Start a fresh SketchUp 2026 session with one known SKP and the pinned runtime. Verify that the selected export profile and format match the metadata below. Run the collector immediately before starting the export manually, and collect through completion. **The sampling window is not a measurement of export start/end**: retain the SketchUp receipt for wall time.

    & $probe -Mode Capture -HostClaimConfirmed -RunId y_bomc_exact_cold_01 -Samples 240 -SourceSkp 'D:\path\to\private\RUMAH Y.skp' -InstallReceipt $install -PackageRbz $rbz -WireEngineId e4 -Profile exact -Cache cold -AdapterMode default

Physical labels map to legacy IDs: E1 Canonical = e2, E2 CleanPKG = e3, E3 BOMC = e4. Run needed Exact, Visual, and Export All scenarios separately. Repeat cold/warm on the same build/input. Preserve failure and cancellation receipts.

For Export All, pass -ExportMode export_all with the chosen profile and omit -WireEngineId; the run then covers multiple physical exporters. Keep each resulting output and stage receipt separately.

Samples contain timestamps, process CPU-time, thread CPU-time, per-logical-core usage/frequency, PID/LUID/physical/engine GPU activity, GPU adapter memory, disk throughput/queue, and host available memory. Optional NVIDIA temperature/power/clock samples are tagged with their source; Intel sensor availability is not inferred. Performance counters may require more than one second per sample. The HostClaimConfirmed switch is an explicit operator assertion of exclusive host ownership, not an automatic distributed lock.

For BOMC, internal tracing normally writes an export.performance.json sibling (or export.performance.STATUS.json on failure), when enabled. Join with external telemetry:

    & $probe -Mode Finalize -RunId y_bomc_exact_cold_01 -ArtifactPath 'D:\SibamboExports\my-export.bomc' -StageReceipt 'D:\SibamboExports\my-export.bomc.performance.json'

Finalized receipts keep timing stages and sampled peaks separate. Loaded source, GPU LUID brand mapping, output readback, fidelity, and causality remain unverified until independently proved. Installed source SHA is only a filesystem provenance pin.

## GPU A/B and interpretation

When the exclusive host owner permits, record the original **Windows Settings > System > Display > Graphics > SketchUp** preference. Compare Power saving (Intel) with High performance (NVIDIA) on the same input/profile/build/driver and cooling conditions. Restart SketchUp for each mode, verify the actually selected adapter, and restore the original preference. This collector reads GPU preference but never changes it.

GPU Engine counters expose LUID, physical index, PID and 3D/Compute/Copy/Video engine. **LUID is not automatically an Intel/NVIDIA identity**. Confirm the mapping independently; a GPU busy with SketchUp viewport/DWM is not proof of GPU export encoding. Per-core CPU saturation can coexist with low system-wide CPU usage. Never sum peaks across GPU engines and call the total adapter utilization.

Only after repeatable, source-pinned real exports and per-stage traces should a reviewer rank GPU texture capture/readback versus single-thread Ruby/codec, synchronous waiting, or disk. A collector smoke test cannot close SIB-PERF-GPU-00 or certify 30 native rows. Mark unexecuted native and adapter comparison gates NOT RUN with reasons.

## Safe collector test

    & $probe -Mode Capture -RunId smoke_unique_01 -Samples 2 -AllowIdleSmoke
    & $probe -Mode Finalize -RunId smoke_unique_01

The result is tagged collector_smoke_only. It is never a valid native-export measurement.
