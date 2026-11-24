# SketchUp OS Watchdog (`G-RT4'`)

Out-of-process Windows UI stall/hang observer (`skp_watchdog.ps1`), Ruby summarizer (`summarize_watchdog.rb`), and ModelTruth phase beacon (`runbook_beacon.rb`).

> **Governance note:** Gate `G-RT4'` replaces manual `G-RT4` (D37) for SketchUp runs **only after** `Checkpoint A6` and manual pilot `M12` pass. Until then, D37 remains in force.

## 1. Overnight Batch Run (Watched)

Start the watcher in a dedicated PowerShell 5.1 window before or during the batch run (uses `-WatchBatchRoot` default `D:\projects\sibambo\private-evidence\batch-exports` with session-bound freshness filtering and writes outputs to `D:\projects\sibambo\outputs\watchdog\<UTC>-<hex6>\`):

```powershell
$env:TEMP = $env:TMP = 'D:\projects\sibambo\scratch\watchdog\tmp'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "D:\projects\sibambo\scratch\worktrees\sib-r1-wp2-10-watchdog\tools\watchdog\skp_watchdog.ps1" -ExitWhenTargetExits
```

For unattended runs, pass `-MaxDurationSeconds <seconds>` as an upper safety bound. Note the printed output directory path (`<SESSION_DIR>`). After SketchUp exits, run the summarizer:

```powershell
& "C:\Ruby25-x64\bin\ruby.exe" "D:\projects\sibambo\scratch\worktrees\sib-r1-wp2-10-watchdog\tools\watchdog\summarize_watchdog.rb" --session "<SESSION_DIR>"
```

## 2. ModelTruth Run with Beacon

1. Start the watcher in PowerShell with `-BeaconFile` on `D:` (setting `-BeaconFile` automatically disables `-WatchBatchRoot` unless explicitly passed; `-ProgressStaleSeconds 120` emits a non-invasive `capture_progress_stalled` diagnostic if `skp/progress.json` mtime stalls):

```powershell
$env:TEMP = $env:TMP = 'D:\projects\sibambo\scratch\watchdog\tmp'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "D:\projects\sibambo\scratch\worktrees\sib-r1-wp2-10-watchdog\tools\watchdog\skp_watchdog.ps1" -BeaconFile "D:\projects\sibambo\scratch\watchdog\beacon.json" -ExitWhenTargetExits
```

2. Open SketchUp `26.2.243`, open the Ruby Console, and run (`open_and_capture` defers `load_file` + `capture` onto the next UI tick via `UI.start_timer(0.05, false)` so post-open viewport settle stays attributed to `open_file` and `stage_timings_ms` are recorded):

```ruby
load 'D:/projects/sibambo/scratch/worktrees/sib-r1-wp2-10-watchdog/tools/watchdog/runbook_beacon.rb'
SibamboWatchdogBeacon.open_and_capture(
  skp_path: '<SKP_PATH>',
  run_dir: '<RUN_DIR_WITH_BOMC>',
  expected_source_sha256: '<EXPECTED_SKP_SHA256>',
  beacon_path: 'D:/projects/sibambo/scratch/watchdog/beacon.json',
  skp_side_path: 'D:/projects/sibambo/scratch/worktrees/sib-r1-wp2-10-skp-side-hardening/tools/model_truth/skp_side.rb'
)
```

3. Poll `SibamboModelTruthV1::SkpSide.status` until `finished: true` (`skp/manifest.json` exists and watcher transitions to `idle` via `capture_terminal`), then close SketchUp without saving.
4. Run the summarizer on `<SESSION_DIR>`:

```powershell
& "C:\Ruby25-x64\bin\ruby.exe" "D:\projects\sibambo\scratch\worktrees\sib-r1-wp2-10-watchdog\tools\watchdog\summarize_watchdog.rb" --session "<SESSION_DIR>"
```

## 3. Summarizer Exit Codes and Outputs

The summarizer writes `episodes.json`, `watchdog-summary.json`, and `watchdog-summary.md` into `<SESSION_DIR>`, including `lifecycle_phases_seen`, `capture_terminals`, `capture_progress_stalls`, and `observer_overhead` (`<= 3.0%` CPU core qualification budget):

- **Exit `0` (`PASS`):** Target seen, WORK ticks observed, and no `G-RT4'-A`, `G-RT4'-U`, or `G-RT4'-D` failure.
- **Exit `1` (`FAIL`):** One or more gate failures:
  - `G-RT4'-A`: Any WORK `hung` segment with `duration_ms > 10000` (default `--work-hung-limit-ms`).
  - `G-RT4'-U`: Any UNKNOWN `hung` segment with `duration_ms > 10000`.
  - `G-RT4'-D`: Any BugSplat child (`bugsplat`/`bssndrpt`), any `process_exited` while last phase class was WORK, any `#32770` modal dialog episode in WORK or UNKNOWN with `duration_ms > 30000` (default `--modal-limit-ms`), or `capture_terminal` with `complete == false` (`CAPTURE_FAILED`).
- **Exit `2` (`ERROR`):** Missing `events.ndjson`, invalid `session_start`, corrupt non-tail NDJSON line, `WATCHDOG_SESSION_ERROR`, `NO_TARGET_SEEN`, or `NO_WORK_OBSERVED`.

## 4. Test Commands

All tests keep `TEMP`/`TMP` on `D:\projects\sibambo\scratch\watchdog\tmp`:

```powershell
$env:TEMP = $env:TMP = 'D:\projects\sibambo\scratch\watchdog\tmp'
& 'C:\Ruby25-x64\bin\ruby.exe' 'tools\watchdog\tests\test_summarize_watchdog.rb'
& 'C:\Ruby25-x64\bin\ruby.exe' 'tools\watchdog\tests\test_runbook_beacon.rb'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'tools\watchdog\tests\test_watchdog_unit.ps1'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'tools\watchdog\tests\test_watchdog_live_win32.ps1'
```
